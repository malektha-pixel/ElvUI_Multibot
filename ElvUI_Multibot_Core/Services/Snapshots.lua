local _, MB = ...

local SNAPSHOT_SCHEMA_VERSION = 1
local CORE_OWNER = "CORE"

local function epochNow()
    if type(time) == "function" then return time() end
    return 0
end

local function normalizeProfile(self, value)
    value = self:Upper(value ~= nil and value or "STANDARD")
    if value ~= "STANDARD" and value ~= "FULL" then return nil end
    return value
end

local function providerSort(a, b)
    if (tonumber(a.order) or 100) ~= (tonumber(b.order) or 100) then
        return (tonumber(a.order) or 100) < (tonumber(b.order) or 100)
    end
    return tostring(a.id or "") < tostring(b.id or "")
end

local function compactMeta(meta)
    if type(meta) ~= "table" then return nil end
    return {
        revision = tonumber(meta.revision) or 0,
        source = meta.source,
        stale = meta.stale == true,
        error = meta.error,
    }
end

local function compactInventory(self, value)
    if type(value) ~= "table" then return value end
    local out = {
        schemaVersion = tonumber(value.schemaVersion) or 1,
        name = value.name,
        summary = self:Copy(value.summary or {}),
        locationModel = value.locationModel or "FLAT",
        hasPhysicalLocations = value.hasPhysicalLocations == true,
        equipmentReadback = value.equipmentReadback == true,
        items = {},
    }
    for _, item in ipairs(value.items or {}) do
        out.items[#out.items + 1] = {
            itemId = tonumber(item.itemId) or 0,
            count = tonumber(item.count) or 1,
            name = item.name,
            link = item.serverLink or item.link,
            quality = item.quality,
            itemLevel = item.itemLevel,
            requiredLevel = item.requiredLevel,
            type = item.type,
            subType = item.subType,
            equipLoc = item.equipLoc,
            icon = item.icon,
            metadataResolved = item.metadataResolved == true,
        }
    end
    return out
end

local function compactExactInventory(self, value)
    if type(value) ~= "table" then return value end
    local out = {
        schemaVersion = tonumber(value.schemaVersion) or 1,
        name = value.name,
        summary = self:Copy(value.summary or {}),
        locationModel = value.locationModel or "PHYSICAL",
        hasPhysicalLocations = value.hasPhysicalLocations == true,
        bags = self:Copy(value.bags or {}),
        items = {},
    }
    for _, item in ipairs(value.items or {}) do
        out.items[#out.items + 1] = {
            bag = tonumber(item.bag),
            slot = tonumber(item.slot),
            itemId = tonumber(item.itemId) or 0,
            count = tonumber(item.count) or 1,
            soulbound = item.soulbound == true,
            name = item.name,
            link = item.serverLink or item.link,
        }
    end
    return out
end

local function identitySnapshot(self, bot)
    bot = bot or {}
    local out = {
        guid = tonumber(bot.guid or bot.altGuid),
        name = bot.name,
        key = bot.key,
        class = bot.class,
        classId = tonumber(bot.classId),
        className = bot.className,
        level = tonumber(bot.level),
        race = bot.race,
        gender = bot.gender,
        score = tonumber(bot.score),
        talent1 = tonumber(bot.talent1),
        talent2 = tonumber(bot.talent2),
        talent3 = tonumber(bot.talent3),
        altbot = bot.altbot == true,
        lifecycleState = bot.lifecycleState,
        online = bot.online == true,
        altOnline = bot.altOnline == true,
        alive = bot.alive,
        mapId = tonumber(bot.mapId),
    }
    -- Reserved for future authoritative guild/faction providers. Never infer these values.
    local passthrough = { "faction", "team", "guildName", "guildId", "guildRank", "guildRankIndex" }
    for _, key in ipairs(passthrough) do if bot[key] ~= nil then out[key] = bot[key] end end
    return out
end

local function snapshotMessage(code, botName)
    botName = botName or "bot"
    local messages = {
        BRIDGE_NOT_CONNECTED = "Snapshot refresh refused: the MultiBot bridge is not connected.",
        BRIDGE_NOT_READY = "Snapshot refresh refused: the MultiBot bridge is not ready.",
        BOT_NOT_FOUND = "Snapshot refresh refused: the bot is not known to Core.",
        BOT_OFFLINE = "Snapshot refresh refused: " .. botName .. " is offline.",
        BOT_GUID_UNAVAILABLE = "Snapshot refresh refused: " .. botName .. " has no authoritative GUID.",
        SNAPSHOT_BUSY = "Snapshot refresh refused: a snapshot for " .. botName .. " is already in progress.",
        INVALID_PROFILE = "Snapshot refresh refused: unknown snapshot profile.",
        NO_PROVIDERS = "Snapshot refresh refused: no snapshot providers were selected.",
        UNKNOWN_SNAPSHOT_PROVIDER = "Snapshot refresh refused: one or more requested snapshot providers are unknown.",
        CONNECTION_LOST = "Snapshot refresh failed: connection was lost before the staged snapshot could be committed.",
        BOT_WENT_OFFLINE = "Snapshot refresh failed: " .. botName .. " went offline before the staged snapshot could be committed.",
        PROVIDER_FAILED = "Snapshot refresh failed: one or more required data providers did not complete successfully.",
        PRESENCE_CHECK_FAILED = "Snapshot refresh failed: Core could not verify the live bridge roster.",
        SNAPSHOT_COMMITTED = "Snapshot captured successfully for " .. botName .. ".",
    }
    return messages[code] or ("Snapshot result: " .. tostring(code or "UNKNOWN"))
end

local function botOnline(self, bot)
    if type(bot) ~= "table" then return false end
    local lifecycle = self:Upper(bot.lifecycleState)

    -- Cached presence is advisory only. Explicit snapshot capture performs a
    -- fresh BRIDGE.ROSTER check before any provider reads and again before
    -- commit, because manual summon/unsummon can race cached lifecycle fields.
    if lifecycle == "DISCONNECTING" then return false end
    if bot.online == true then return true end
    if lifecycle == "OFFLINE" then return false end
    if lifecycle == "ONLINE" or bot.altOnline == true then return true end
    return false
end

local function rosterContainsBot(self, roster, botName)
    local key = self:BotKey(botName)
    if not key then return false end
    for _, item in ipairs(type(roster) == "table" and roster or {}) do
        if self:BotKey(item and item.name) == key then return true end
    end
    return false
end

local function snapshotGuid(bot)
    local guid = bot and tonumber(bot.guid or bot.altGuid) or nil
    if guid and guid > 0 then return guid end
    return nil
end

function MB:RegisterSnapshotProvider(moduleName, providerId, descriptor)
    moduleName = self:Trim(moduleName)
    providerId = self:Upper(providerId)
    if moduleName == "" or providerId == "" or type(descriptor) ~= "table" then return false, "INVALID_SNAPSHOT_PROVIDER" end
    if moduleName ~= CORE_OWNER and not self.modules[moduleName] then self:RegisterModule(moduleName) end
    local current = self.snapshotProviders[providerId]
    if current and current.owner ~= moduleName then return false, "SNAPSHOT_PROVIDER_ALREADY_REGISTERED" end

    local domainId = self:Trim(descriptor.domainId)
    local collector = descriptor.collector
    if domainId == "" and type(collector) ~= "function" then return false, "SNAPSHOT_PROVIDER_SOURCE_REQUIRED" end
    if domainId ~= "" then
        local domain = self.dataDomains[domainId]
        if not domain then return false, "UNKNOWN_DOMAIN" end
        if domain.scope ~= "BOT" then return false, "SNAPSHOT_PROVIDER_BOT_DOMAIN_REQUIRED" end
    end

    local entry = self:Copy(descriptor)
    entry.id = providerId
    entry.owner = moduleName
    entry.domainId = domainId ~= "" and domainId or nil
    entry.collector = collector
    entry.transform = descriptor.transform
    entry.section = self:Trim(descriptor.section ~= nil and descriptor.section or self:Lower(providerId))
    entry.order = tonumber(descriptor.order) or 100
    entry.standard = descriptor.standard == true
    entry.full = descriptor.full == true or entry.standard
    entry.required = descriptor.required ~= false
    self.snapshotProviders[providerId] = entry
    self.snapshotProviderByModule[moduleName] = self.snapshotProviderByModule[moduleName] or {}
    self.snapshotProviderByModule[moduleName][providerId] = true
    self:Emit("MB_REGISTRY_CHANGED", "SNAPSHOT_PROVIDER", providerId)
    return true
end

function MB:UnregisterSnapshotProvider(moduleName, providerId)
    moduleName, providerId = self:Trim(moduleName), self:Upper(providerId)
    local entry = self.snapshotProviders[providerId]
    if not entry or entry.owner ~= moduleName or moduleName == CORE_OWNER then return false end
    self.snapshotProviders[providerId] = nil
    if self.snapshotProviderByModule[moduleName] then self.snapshotProviderByModule[moduleName][providerId] = nil end
    self:Emit("MB_REGISTRY_CHANGED", "SNAPSHOT_PROVIDER", providerId)
    return true
end

function MB:ClearModuleSnapshotProviders(moduleName)
    local bucket = self.snapshotProviderByModule[moduleName]
    if not bucket then return end
    local ids = {}
    for id in pairs(bucket) do ids[#ids + 1] = id end
    for _, id in ipairs(ids) do self:UnregisterSnapshotProvider(moduleName, id) end
    self.snapshotProviderByModule[moduleName] = nil
end

function MB:GetSnapshotProviders()
    local out = {}
    for _, provider in pairs(self.snapshotProviders or {}) do
        local copy = self:Copy(provider)
        copy.collector, copy.transform = nil, nil
        out[#out + 1] = copy
    end
    table.sort(out, providerSort)
    return out
end

function MB:GetSnapshotProfile(profileName)
    profileName = normalizeProfile(self, profileName)
    if not profileName then return nil, "INVALID_PROFILE" end
    local out = {}
    for _, provider in pairs(self.snapshotProviders or {}) do
        local include = profileName == "STANDARD" and provider.standard == true or profileName == "FULL" and provider.full == true
        if include then out[#out + 1] = provider.id end
    end
    table.sort(out, function(a, b) return providerSort(self.snapshotProviders[a], self.snapshotProviders[b]) end)
    return { name = profileName, providers = out }
end

function MB:InitializeSnapshotStore()
    local saved = _G.ElvUI_Multibot_SnapshotsDB
    if type(saved) ~= "table" then saved = {}; _G.ElvUI_Multibot_SnapshotsDB = saved end
    if tonumber(saved.schemaVersion) ~= SNAPSHOT_SCHEMA_VERSION then
        -- First persistent schema. Future versions must migrate rather than projecting old data into live state.
        saved.schemaVersion = SNAPSHOT_SCHEMA_VERSION
        saved.bots = type(saved.bots) == "table" and saved.bots or {}
    end
    saved.schemaVersion = SNAPSHOT_SCHEMA_VERSION
    saved.bots = type(saved.bots) == "table" and saved.bots or {}
    saved.nameIndex = {}
    for guidKey, snapshot in pairs(saved.bots) do
        if type(snapshot) == "table" and self:Trim(snapshot.name) ~= "" then
            saved.nameIndex[self:BotKey(snapshot.name)] = tostring(guidKey)
        end
    end
    self.snapshotStore = saved
    self.snapshotActiveByGuid = {}
end

-- Removes the one persisted STANDARD/FULL snapshot record owned by a managed
-- GUID. Callers must preflight active snapshot work before invoking this helper.
function MB:ForgetSnapshotForManagedBot(guidKey, name)
    if not self.snapshotStore then return 0 end
    guidKey = tostring(guidKey or "")
    if guidKey == "" then return 0 end
    local snapshot = self.snapshotStore.bots and self.snapshotStore.bots[guidKey] or nil
    if snapshot == nil then return 0 end

    local storedName = snapshot.name or name
    local nameKey = self:BotKey(storedName)
    if nameKey and self.snapshotStore.nameIndex and self.snapshotStore.nameIndex[nameKey] == guidKey then
        self.snapshotStore.nameIndex[nameKey] = nil
    end
    self.snapshotStore.bots[guidKey] = nil
    return 1
end

function MB:ResolveSnapshotKey(botRef)
    local directGuid
    if type(botRef) == "number" then directGuid = tonumber(botRef)
    elseif type(botRef) == "table" then directGuid = tonumber(botRef.guid or botRef.altGuid) end
    if not directGuid and type(botRef) == "string" then
        local trimmed = self:Trim(botRef)
        if string.match(trimmed, "^%d+$") then directGuid = tonumber(trimmed) end
    end
    if directGuid and directGuid > 0 then return tostring(math.floor(directGuid)) end

    local bot = self:ResolveBot(botRef)
    local guid = snapshotGuid(bot)
    if guid then return tostring(math.floor(guid)) end
    local name = type(botRef) == "table" and (botRef.name or botRef.bot or botRef.target) or botRef
    local key = self:BotKey(name)
    return key and self.snapshotStore and self.snapshotStore.nameIndex and self.snapshotStore.nameIndex[key] or nil
end

function MB:GetBotSnapshot(botRef)
    if not self.snapshotStore then return nil, { status = "UNAVAILABLE", error = "SNAPSHOT_STORE_NOT_READY" } end
    local key = self:ResolveSnapshotKey(botRef)
    if not key then return nil, { status = "MISSING" } end
    local snapshot = self.snapshotStore.bots[key]
    if not snapshot then return nil, { status = "MISSING", guidKey = key } end
    return self:Copy(snapshot), { status = "OK", guidKey = key, schemaVersion = self.snapshotStore.schemaVersion }
end

function MB:GetBotSnapshots()
    local out = {}
    if not self.snapshotStore then return out end
    for _, snapshot in pairs(self.snapshotStore.bots or {}) do out[#out + 1] = self:Copy(snapshot) end
    table.sort(out, function(a, b) return tostring(a.name or "") < tostring(b.name or "") end)
    return out
end

function MB:GetBotSnapshotStatus(botRef)
    local snapshot, meta = self:GetBotSnapshot(botRef)
    local bot = self:ResolveBot(botRef)
    local capturedAt = snapshot and tonumber(snapshot.capturedAt) or nil
    local nowEpoch = epochNow()
    return {
        exists = snapshot ~= nil,
        status = snapshot and "AVAILABLE" or "MISSING",
        guid = snapshot and snapshot.guid or snapshotGuid(bot),
        name = snapshot and snapshot.name or (bot and bot.name),
        capturedAt = capturedAt,
        ageSeconds = capturedAt and nowEpoch > 0 and math.max(0, nowEpoch - capturedAt) or nil,
        profile = snapshot and snapshot.profile or nil,
        complete = snapshot and snapshot.complete == true or false,
        currentOnline = botOnline(self, bot),
        currentLifecycleState = bot and bot.lifecycleState or nil,
        meta = meta,
    }
end

function MB:GetSnapshotRefreshAvailability(botRef, options)
    options = type(options) == "table" and options or {}
    local profile = normalizeProfile(self, options.profile)
    local bot = self:ResolveBot(botRef)
    local name = bot and bot.name or self:NormalizeName(type(botRef) == "table" and (botRef.name or botRef.bot or botRef.target) or botRef)
    if not profile then return { enabled = false, reason = "INVALID_PROFILE", message = snapshotMessage("INVALID_PROFILE", name), profile = options.profile } end
    if not self.bridge.connected then return { enabled = false, reason = "BRIDGE_NOT_CONNECTED", message = snapshotMessage("BRIDGE_NOT_CONNECTED", name), profile = profile } end
    if not self.bridge.handshakeReady or self.bridge.capabilitiesResolved ~= true then return { enabled = false, reason = "BRIDGE_NOT_READY", message = snapshotMessage("BRIDGE_NOT_READY", name), profile = profile } end
    if not bot then return { enabled = false, reason = "BOT_NOT_FOUND", message = snapshotMessage("BOT_NOT_FOUND", name), profile = profile } end
    if self:Upper(bot.lifecycleState) == "DISCONNECTING" then
        return { enabled = false, reason = "BOT_OFFLINE", message = snapshotMessage("BOT_OFFLINE", bot.name), profile = profile, bot = self:Copy(bot) }
    end
    local guid = snapshotGuid(bot)
    if not guid then return { enabled = false, reason = "BOT_GUID_UNAVAILABLE", message = snapshotMessage("BOT_GUID_UNAVAILABLE", bot.name), profile = profile, bot = self:Copy(bot) } end
    if self.snapshotActiveByGuid and self.snapshotActiveByGuid[guid] then
        return { enabled = false, reason = "SNAPSHOT_BUSY", message = snapshotMessage("SNAPSHOT_BUSY", bot.name), profile = profile, bot = self:Copy(bot), guid = guid }
    end
    local profileInfo = self:GetSnapshotProfile(profile)
    local providers = options.providers
    if type(providers) ~= "table" then providers = profileInfo and profileInfo.providers or {} end
    local normalizedProviders, seenProviders = {}, {}
    for _, providerId in ipairs(providers) do
        providerId = self:Upper(providerId)
        if providerId ~= "" and not self.snapshotProviders[providerId] then
            return { enabled = false, reason = "UNKNOWN_SNAPSHOT_PROVIDER", message = snapshotMessage("UNKNOWN_SNAPSHOT_PROVIDER", bot.name), profile = profile, bot = self:Copy(bot), guid = guid, providerId = providerId }
        end
        if providerId ~= "" and not seenProviders[providerId] then
            seenProviders[providerId] = true
            normalizedProviders[#normalizedProviders + 1] = providerId
        end
    end
    if #normalizedProviders == 0 then return { enabled = false, reason = "NO_PROVIDERS", message = snapshotMessage("NO_PROVIDERS", bot.name), profile = profile, bot = self:Copy(bot), guid = guid } end
    return {
        enabled = true, reason = nil, message = "Snapshot refresh can perform a fresh live-roster preflight.",
        profile = profile, bot = self:Copy(bot), guid = guid, providers = normalizedProviders, strict = options.allowPartial ~= true,
        cachedOnline = botOnline(self, bot), requiresFreshPresence = true, presenceAuthority = "BRIDGE.ROSTER",
    }
end

local function emitSnapshotResult(self, request, code, extra)
    local result = {
        requestId = request and request.id or nil,
        ok = code == "SNAPSHOT_COMMITTED",
        status = code == "SNAPSHOT_COMMITTED" and "COMMITTED" or ((code == "BRIDGE_NOT_CONNECTED" or code == "BRIDGE_NOT_READY" or code == "BOT_NOT_FOUND" or code == "BOT_OFFLINE" or code == "BOT_GUID_UNAVAILABLE" or code == "SNAPSHOT_BUSY" or code == "INVALID_PROFILE" or code == "NO_PROVIDERS" or code == "UNKNOWN_SNAPSHOT_PROVIDER") and "REFUSED" or "FAILED"),
        code = code,
        message = snapshotMessage(code, request and request.botName),
        botName = request and request.botName or nil,
        guid = request and request.guid or nil,
        profile = request and request.profile or nil,
    }
    for k, v in pairs(extra or {}) do result[k] = v end
    self:Emit("MB_SNAPSHOT_RESULT", self:Copy(result))
    if request and type(request.callback) == "function" then self:SafeCall(request.callback, self:Copy(result)) end
    return result
end

local function buildSnapshot(self, request)
    local bot = self:ResolveBot(request.botName)
    local sections = self:Copy(request.sections or {})
    sections.identity = identitySnapshot(self, bot)
    local providerResults = self:Copy(request.providerResults or {})
    providerResults.IDENTITY = providerResults.IDENTITY or { status = "OK", section = "identity", source = "BOT.REGISTRY" }
    local failures = self:Copy(request.failures or {})
    local snapshot = {
        schemaVersion = SNAPSHOT_SCHEMA_VERSION,
        guid = request.guid,
        name = bot and bot.name or request.botName,
        botKey = bot and bot.key or self:BotKey(request.botName),
        capturedAt = epochNow(),
        coreVersion = self.version,
        apiVersion = self.API_VERSION,
        sessionEpoch = self.sessionEpoch,
        profile = request.profile,
        complete = #failures == 0,
        sections = sections,
        providers = providerResults,
        failures = failures,
        capturePresence = {
            lifecycleState = bot and bot.lifecycleState or nil,
            online = bot and bot.online == true or false,
            altOnline = bot and bot.altOnline == true or false,
            bridgeConnected = self.bridge.connected == true,
            authority = "BRIDGE.ROSTER",
            verifiedAtStart = request.presenceVerifiedAtStart == true,
            verifiedAtCommit = request.presenceVerifiedAtCommit == true,
        },
    }
    return snapshot
end

local function hasRequiredFailure(request)
    for _, failure in ipairs(request.failures or {}) do
        if failure.required == true then return true end
    end
    return false
end

local function releaseSnapshotRequest(self, request)
    if not request or request.finished then return false end
    request.finished = true
    if self.snapshotActiveByGuid[request.guid] == request.id then self.snapshotActiveByGuid[request.guid] = nil end
    self.snapshotRequests[request.id] = nil
    return true
end

local function failSnapshotRequest(self, request, code, extra)
    if not request or request.finished then return nil end
    releaseSnapshotRequest(self, request)
    return emitSnapshotResult(self, request, code, extra)
end

local function commitSnapshot(self, request)
    if request.finished then return nil end
    if not self.bridge.connected or request.sessionEpoch ~= self.sessionEpoch then
        return failSnapshotRequest(self, request, "CONNECTION_LOST", { failures = self:Copy(request.failures or {}) })
    end
    if request.strict and hasRequiredFailure(request) then
        return failSnapshotRequest(self, request, "PROVIDER_FAILED", { failures = self:Copy(request.failures or {}), providerResults = self:Copy(request.providerResults or {}) })
    end
    if request.presenceVerifiedAtStart ~= true or request.presenceVerifiedAtCommit ~= true then
        return failSnapshotRequest(self, request, "PRESENCE_CHECK_FAILED", { failures = self:Copy(request.failures or {}) })
    end

    local snapshot = buildSnapshot(self, request)
    local guidKey = tostring(request.guid)
    local old = self.snapshotStore.bots[guidKey]
    if old and old.name then
        local oldNameKey = self:BotKey(old.name)
        if oldNameKey and self.snapshotStore.nameIndex[oldNameKey] == guidKey then self.snapshotStore.nameIndex[oldNameKey] = nil end
    end
    self.snapshotStore.bots[guidKey] = self:Copy(snapshot)
    if snapshot.name then self.snapshotStore.nameIndex[self:BotKey(snapshot.name)] = guidKey end
    if self.RecordManagedSnapshot then self:RecordManagedSnapshot(snapshot) end
    self:Emit("MB_SNAPSHOT_UPDATED", guidKey, self:Copy(snapshot))
    releaseSnapshotRequest(self, request)
    return emitSnapshotResult(self, request, "SNAPSHOT_COMMITTED", { snapshot = self:Copy(snapshot), providerResults = self:Copy(request.providerResults or {}), failures = self:Copy(request.failures or {}) })
end

local function beginCommitPresenceCheck(self, request)
    if request.finished or request.commitCheckStarted == true then return end
    request.commitCheckStarted = true
    if not self.bridge.connected or request.sessionEpoch ~= self.sessionEpoch then
        failSnapshotRequest(self, request, "CONNECTION_LOST", { failures = self:Copy(request.failures or {}) })
        return
    end
    if request.strict and hasRequiredFailure(request) then
        failSnapshotRequest(self, request, "PROVIDER_FAILED", { failures = self:Copy(request.failures or {}), providerResults = self:Copy(request.providerResults or {}) })
        return
    end

    local readId, err = self:RefreshDomain("BRIDGE.ROSTER", nil, function(roster, meta)
        if request.finished then return end
        if request.sessionEpoch ~= MB.sessionEpoch or not MB.bridge.connected then
            failSnapshotRequest(MB, request, "CONNECTION_LOST", { failures = MB:Copy(request.failures or {}) })
            return
        end
        if type(roster) ~= "table" or (meta and meta.status == "ERROR") then
            failSnapshotRequest(MB, request, "PRESENCE_CHECK_FAILED", {
                failures = MB:Copy(request.failures or {}),
                presenceError = meta and (meta.error or meta.status) or "NO_ROSTER_DATA",
            })
            return
        end
        if not rosterContainsBot(MB, roster, request.botName) then
            failSnapshotRequest(MB, request, "BOT_WENT_OFFLINE", { failures = MB:Copy(request.failures or {}) })
            return
        end
        request.presenceVerifiedAtCommit = true
        request.commitPresenceReadId = readId
        MB:After(0, function()
            if not request.finished then commitSnapshot(MB, request) end
        end)
    end, { timeout = tonumber(request.options and request.options.presenceTimeout) or nil })
    request.commitPresenceReadId = readId
    if not readId then
        failSnapshotRequest(self, request, "PRESENCE_CHECK_FAILED", {
            failures = self:Copy(request.failures or {}), presenceError = err or "DISPATCH_FAILED",
        })
    end
end

local function finishSnapshotProviders(self, request)
    if request.finished or request.providersSettled == true then return end
    request.providersSettled = true
    beginCommitPresenceCheck(self, request)
end

local function providerSettled(self, request, provider, value, meta, immediateError)
    if request.finished or request.sessionEpoch ~= self.sessionEpoch then return end
    local failed = immediateError or (meta and meta.status == "ERROR") or value == nil
    if failed then
        local code = immediateError or (meta and (meta.error or meta.status)) or "NO_DATA"
        request.failures[#request.failures + 1] = { providerId = provider.id, domainId = provider.domainId, code = code, required = provider.required == true }
        request.providerResults[provider.id] = { status = "ERROR", error = code, domainId = provider.domainId, section = provider.section, required = provider.required == true }
    else
        local stored = value
        if type(provider.transform) == "function" then
            local ok, transformed = pcall(provider.transform, self, value, meta, request)
            if ok then stored = transformed
            else
                local code = "TRANSFORM_FAILED"
                request.failures[#request.failures + 1] = { providerId = provider.id, domainId = provider.domainId, code = code, required = provider.required == true }
                request.providerResults[provider.id] = { status = "ERROR", error = code, domainId = provider.domainId, section = provider.section, required = provider.required == true }
                request.pending = request.pending - 1
                self:Emit("MB_SNAPSHOT_PROGRESS", request.id, provider.id, self:Copy(request.providerResults[provider.id]))
                if request.pending <= 0 and request.dispatching ~= true then finishSnapshotProviders(self, request) end
                return
            end
        end
        request.sections[provider.section] = self:Copy(stored)
        request.providerResults[provider.id] = {
            status = "OK", domainId = provider.domainId, section = provider.section, required = provider.required == true,
            meta = compactMeta(meta),
        }
    end
    request.pending = request.pending - 1
    self:Emit("MB_SNAPSHOT_PROGRESS", request.id, provider.id, self:Copy(request.providerResults[provider.id]))
    if request.pending <= 0 and request.dispatching ~= true then finishSnapshotProviders(self, request) end
end

local function startSnapshotProviders(self, request, availability)
    if request.finished then return end
    local liveBot = self:ResolveBot(request.botName)
    if not liveBot then
        failSnapshotRequest(self, request, "BOT_NOT_FOUND")
        return
    end
    if snapshotGuid(liveBot) ~= request.guid then
        failSnapshotRequest(self, request, "BOT_GUID_UNAVAILABLE")
        return
    end

    request.dispatching = true
    self:Emit("MB_SNAPSHOT_STARTED", request.id, self:Copy({
        botName = request.botName, guid = request.guid, profile = request.profile, providers = availability.providers,
        presenceAuthority = "BRIDGE.ROSTER", presenceVerified = true,
    }))

    local seen = {}
    local providers = {}
    for _, id in ipairs(availability.providers or {}) do
        id = self:Upper(id)
        local provider = self.snapshotProviders[id]
        if provider and not seen[id] then seen[id] = true; providers[#providers + 1] = provider end
    end
    table.sort(providers, providerSort)

    for _, provider in ipairs(providers) do
        if provider.id == "IDENTITY" then
            request.sections[provider.section] = identitySnapshot(self, liveBot)
            request.providerResults[provider.id] = { status = "OK", section = provider.section, source = "BOT.REGISTRY", required = provider.required == true }
        else
            request.pending = request.pending + 1
            if provider.domainId then
                local readId, err = self:RefreshDomain(provider.domainId, request.botName, function(value, meta)
                    providerSettled(MB, request, provider, value, meta, nil)
                end, { timeout = tonumber(request.options and request.options.timeout) or nil })
                if not readId then providerSettled(self, request, provider, nil, nil, err or "DISPATCH_FAILED") end
            elseif type(provider.collector) == "function" then
                local ok, value, metaOrError = pcall(provider.collector, self, request.botName, self:Copy(request.options or {}))
                if not ok then providerSettled(self, request, provider, nil, nil, "COLLECTOR_FAILED")
                elseif value == nil then providerSettled(self, request, provider, nil, nil, metaOrError or "NO_DATA")
                else providerSettled(self, request, provider, value, type(metaOrError) == "table" and metaOrError or nil, nil) end
            end
        end
    end

    request.dispatching = false
    if request.pending <= 0 then finishSnapshotProviders(self, request) end
end

function MB:RequestBotSnapshot(botRef, callback, options)
    options = type(options) == "table" and options or {}
    local availability = self:GetSnapshotRefreshAvailability(botRef, options)
    if not availability.enabled then
        local pseudo = { botName = availability.bot and availability.bot.name or self:NormalizeName(botRef), guid = availability.guid, profile = availability.profile, callback = callback }
        emitSnapshotResult(self, pseudo, availability.reason, { availability = self:Copy(availability) })
        return nil, availability.reason
    end

    self.snapshotRequestSequence = (self.snapshotRequestSequence or 0) + 1
    local request = {
        id = "snapshot-" .. tostring(self.snapshotRequestSequence),
        botName = availability.bot.name,
        botKey = availability.bot.key,
        guid = availability.guid,
        profile = availability.profile,
        strict = availability.strict ~= false,
        sessionEpoch = self.sessionEpoch,
        startedAt = self:Now(),
        callback = callback,
        options = self:Copy(options),
        sections = {},
        providerResults = {},
        failures = {},
        pending = 0,
        dispatching = false,
        finished = false,
        presenceVerifiedAtStart = false,
        presenceVerifiedAtCommit = false,
    }
    self.snapshotRequests[request.id] = request
    self.snapshotActiveByGuid[request.guid] = request.id

    -- Fresh live-roster preflight. Cached bot.online/lifecycle values are not
    -- sufficient because manual summon/unsummon can race those caches.
    local readId, err = self:RefreshDomain("BRIDGE.ROSTER", nil, function(roster, meta)
        if request.finished then return end
        if request.sessionEpoch ~= MB.sessionEpoch or not MB.bridge.connected then
            failSnapshotRequest(MB, request, "CONNECTION_LOST")
            return
        end
        if type(roster) ~= "table" or (meta and meta.status == "ERROR") then
            failSnapshotRequest(MB, request, "PRESENCE_CHECK_FAILED", {
                presenceError = meta and (meta.error or meta.status) or "NO_ROSTER_DATA",
            })
            return
        end
        if not rosterContainsBot(MB, roster, request.botName) then
            failSnapshotRequest(MB, request, "BOT_OFFLINE", { availability = MB:Copy(availability) })
            return
        end
        request.presenceVerifiedAtStart = true
        request.startPresenceReadId = readId
        MB:After(0, function()
            if not request.finished then startSnapshotProviders(MB, request, availability) end
        end)
    end, { timeout = tonumber(options.presenceTimeout) or nil })
    request.startPresenceReadId = readId
    if not readId then
        failSnapshotRequest(self, request, "PRESENCE_CHECK_FAILED", { presenceError = err or "DISPATCH_FAILED" })
        return nil, err or "PRESENCE_CHECK_FAILED"
    end
    return request.id
end

-- Core providers. STANDARD is deliberately useful but bounded; FULL opts into heavier durable reads.
MB:RegisterSnapshotProvider(CORE_OWNER, "IDENTITY", { section = "identity", collector = function(self, name) return identitySnapshot(self, self:ResolveBot(name)) end, order = 1, standard = true, full = true, required = true })
MB:RegisterSnapshotProvider(CORE_OWNER, "DETAIL", { section = "detail", domainId = "BOT.DETAIL", order = 10, standard = true, full = true, required = true })
MB:RegisterSnapshotProvider(CORE_OWNER, "STATE", { section = "state", domainId = "BOT.STATE", order = 20, standard = true, full = true, required = true })
MB:RegisterSnapshotProvider(CORE_OWNER, "STATS", { section = "stats", domainId = "BOT.STATS", order = 30, standard = true, full = true, required = true })
MB:RegisterSnapshotProvider(CORE_OWNER, "INVENTORY", { section = "inventory", domainId = "BOT.INVENTORY", order = 50, standard = true, full = true, required = true, transform = compactInventory })
MB:RegisterSnapshotProvider(CORE_OWNER, "QUESTS", { section = "quests", domainId = "BOT.QUESTS", order = 60, standard = true, full = true, required = true })
MB:RegisterSnapshotProvider(CORE_OWNER, "PROFESSIONS", { section = "professions", domainId = "BOT.PROFESSIONS", order = 70, full = true, required = false })
MB:RegisterSnapshotProvider(CORE_OWNER, "PVP_STATS", { section = "pvpStats", domainId = "BOT.PVP_STATS", order = 80, full = true, required = false })
MB:RegisterSnapshotProvider(CORE_OWNER, "GLYPHS", { section = "glyphs", domainId = "BOT.GLYPHS", order = 90, full = true, required = false })
MB:RegisterSnapshotProvider(CORE_OWNER, "SPELLBOOK", { section = "spellbook", domainId = "BOT.SPELLBOOK", order = 100, full = true, required = false })
MB:RegisterSnapshotProvider(CORE_OWNER, "SKILLS", { section = "skills", domainId = "BOT.SKILLS", order = 110, full = true, required = false })
MB:RegisterSnapshotProvider(CORE_OWNER, "REPUTATIONS", { section = "reputations", domainId = "BOT.REPUTATIONS", order = 120, full = true, required = false })
MB:RegisterSnapshotProvider(CORE_OWNER, "EMBLEMS", { section = "emblems", domainId = "BOT.EMBLEMS", order = 130, full = true, required = false })
MB:RegisterSnapshotProvider(CORE_OWNER, "INVENTORY_EXACT", { section = "inventoryExact", domainId = "BOT.INVENTORY_EXACT", order = 140, full = true, required = false, transform = compactExactInventory })
