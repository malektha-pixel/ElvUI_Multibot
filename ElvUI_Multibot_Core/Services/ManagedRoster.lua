local _, MB = ...

local MANAGED_SCHEMA_VERSION = 1
local AUTH_MAX_AGE_SECONDS = 3

local function epochNow()
    if type(time) == "function" then return time() end
    return 0
end

local function addSource(entry, source)
    source = tostring(source or "")
    if source == "" then return end
    entry.sources = type(entry.sources) == "table" and entry.sources or {}
    entry.sources[source] = true
end

local function managedGuid(bot)
    local guid = bot and tonumber(bot.guid or bot.altGuid) or nil
    return guid and guid > 0 and guid or nil
end

function MB:InitializeManagedRosterStore()
    local saved = _G.ElvUI_Multibot_ManagedDB
    if type(saved) ~= "table" then saved = {}; _G.ElvUI_Multibot_ManagedDB = saved end
    saved.schemaVersion = MANAGED_SCHEMA_VERSION
    saved.entries = type(saved.entries) == "table" and saved.entries or {}
    saved.nameIndex = type(saved.nameIndex) == "table" and saved.nameIndex or {}
    saved.nameIndex = {}
    for guidKey, entry in pairs(saved.entries) do
        if type(entry) == "table" and self:Trim(entry.name) ~= "" then
            saved.nameIndex[self:BotKey(entry.name)] = tostring(guidKey)
            self:UpsertBot(entry.name, {
                guid = tonumber(entry.guid), managedKnown = true, managedPersisted = true,
                classId = tonumber(entry.classId), class = entry.class, level = tonumber(entry.level), race = entry.race,
            }, "MANAGED.STORE")
        end
    end
    self.managedStore = saved
    self.managedSessionAuthByGuid = {}

    if self.snapshotStore and type(self.snapshotStore.bots) == "table" then
        for _, snapshot in pairs(self.snapshotStore.bots) do self:RecordManagedSnapshot(snapshot) end
    end
end

function MB:ResetManagedSessionState()
    self.managedSessionAuthByGuid = {}
end

function MB:RecordManagedIdentity(name, guid, source, fields)
    if not self.managedStore then return nil, "MANAGED_STORE_NOT_READY" end
    name = self:NormalizeName(name)
    guid = tonumber(guid)
    if not name or not guid or guid <= 0 then return nil, "INVALID_MANAGED_IDENTITY" end
    local guidKey = tostring(guid)
    local current = self.managedStore.entries[guidKey]
    local entry = type(current) == "table" and self:Copy(current) or {
        schemaVersion = MANAGED_SCHEMA_VERSION, guid = guid, firstSeenAt = epochNow(), sources = {},
    }
    if entry.name and self:BotKey(entry.name) ~= self:BotKey(name) then
        local oldKey = self:BotKey(entry.name)
        if oldKey and self.managedStore.nameIndex[oldKey] == guidKey then self.managedStore.nameIndex[oldKey] = nil end
    end
    entry.guid = guid
    entry.name = name
    entry.lastSeenAt = epochNow()
    entry.schemaVersion = MANAGED_SCHEMA_VERSION
    addSource(entry, source)
    fields = type(fields) == "table" and fields or {}
    local persistKeys = {
        "class", "classId", "className", "level", "race", "gender", "faction", "team",
        "guildName", "guildId", "guildRank", "guildRankIndex", "lastKnownLifecycle",
    }
    for _, key in ipairs(persistKeys) do if fields[key] ~= nil then entry[key] = self:Copy(fields[key]) end end
    if source == "ALT_ROSTER" then
        entry.altRosterEver = true
        entry.lastAltRosterAt = epochNow()
    elseif source == "BOT_TARGET_RESOLVE" then
        entry.lastResolvedAt = epochNow()
    elseif source == "SNAPSHOT" then
        entry.lastSnapshotAt = tonumber(fields.capturedAt) or epochNow()
        entry.lastSnapshotProfile = fields.profile
        entry.lastSnapshotComplete = fields.complete == true
    end
    self.managedStore.entries[guidKey] = entry
    self.managedStore.nameIndex[self:BotKey(name)] = guidKey
    self:UpsertBot(name, {
        guid = guid, managedKnown = true, managedPersisted = true,
        classId = tonumber(entry.classId), class = entry.class, level = tonumber(entry.level), race = entry.race,
    }, "MANAGED." .. tostring(source or "KNOWN"))
    self:Emit("MB_MANAGED_ROSTER_UPDATED", guidKey, self:Copy(entry), tostring(source or "KNOWN"))
    -- If useful live data arrived before Core learned this bot's stable managed GUID,
    -- retain it now without issuing any additional reads.
    if self.BackfillLastKnownForBot then self:BackfillLastKnownForBot(guidKey) end
    return self:Copy(entry)
end

function MB:SyncManagedAltRoster(snapshot)
    local items = type(snapshot) == "table" and snapshot.items or nil
    if type(items) ~= "table" then return false end
    for _, item in ipairs(items) do
        self:RecordManagedIdentity(item.name, item.guid, "ALT_ROSTER", {
            classId = tonumber(item.classId), level = tonumber(item.level),
            lastKnownLifecycle = self:Upper(item.state),
        })
    end
    return true
end

function MB:RecordManagedResolution(value)
    if type(value) ~= "table" or self:Upper(value.status) ~= "OK" then return false end
    local name = self:NormalizeName(value.name)
    local guid = tonumber(value.guid)
    local lifecycleState = self:Upper(value.lifecycleState)
    if not name or not guid or guid <= 0 then return false end
    self:RecordManagedIdentity(name, guid, "BOT_TARGET_RESOLVE", { lastKnownLifecycle = lifecycleState })
    self.managedSessionAuthByGuid = self.managedSessionAuthByGuid or {}
    self.managedSessionAuthByGuid[guid] = {
        guid = guid, name = name, nameKey = self:BotKey(name), sessionEpoch = self.sessionEpoch,
        resolvedAt = self:Now(), lifecycleState = lifecycleState, source = "BOT_TARGET_RESOLVE",
    }
    self:Emit("MB_MANAGED_AUTH_UPDATED", guid, name, "AUTHORIZED", "BOT_TARGET_RESOLVE")
    return true
end

function MB:RecordManagedLifecycleState(guid, name, lifecycleState, source)
    guid = tonumber(guid)
    name = self:NormalizeName(name)
    lifecycleState = self:Upper(lifecycleState)
    if not guid or guid <= 0 or not name then return false end
    self:RecordManagedIdentity(name, guid, source or "BOT_LIFECYCLE", { lastKnownLifecycle = lifecycleState })
    local auth = self.managedSessionAuthByGuid and self.managedSessionAuthByGuid[guid]
    if auth and auth.sessionEpoch == self.sessionEpoch then auth.lifecycleState = lifecycleState end
    return true
end

function MB:RecordManagedSnapshot(snapshot)
    if type(snapshot) ~= "table" then return false end
    local guid = tonumber(snapshot.guid)
    local name = self:NormalizeName(snapshot.name)
    if not guid or guid <= 0 or not name then return false end
    local identity = snapshot.sections and snapshot.sections.identity or {}
    self:RecordManagedIdentity(name, guid, "SNAPSHOT", {
        class = identity.class, classId = identity.classId, className = identity.className,
        level = identity.level, race = identity.race, gender = identity.gender,
        faction = identity.faction, team = identity.team,
        guildName = identity.guildName, guildId = identity.guildId, guildRank = identity.guildRank, guildRankIndex = identity.guildRankIndex,
        capturedAt = snapshot.capturedAt, profile = snapshot.profile, complete = snapshot.complete,
        lastKnownLifecycle = identity.lifecycleState,
    })
    return true
end

function MB:GetManagedAuthorization(botRef)
    local bot = self:ResolveBot(botRef)
    if bot then
        local guid = managedGuid(bot)
        if bot.altbot == true and bot.altRosterPresent == true and guid then
            return {
                authorized = true, source = "ALT_ROSTER", sessionBound = false, guid = guid, name = bot.name,
                lifecycleState = self:Upper(bot.lifecycleState),
            }
        end
        local auth = guid and self.managedSessionAuthByGuid and self.managedSessionAuthByGuid[guid] or nil
        if auth and auth.sessionEpoch == self.sessionEpoch and auth.nameKey == self:BotKey(bot.name)
            and (self:Now() - (tonumber(auth.resolvedAt) or 0)) <= AUTH_MAX_AGE_SECONDS then
            return {
                authorized = true, source = "BOT_TARGET_RESOLVE", sessionBound = true, guid = guid, name = bot.name,
                lifecycleState = self:Upper(auth.lifecycleState), resolvedAt = auth.resolvedAt,
            }
        end
    end
    return { authorized = false, source = "NONE", sessionBound = true, reason = "TARGET_RESOLVE_REQUIRED" }
end

function MB:GetLifecycleExecutionAuthority(botRef)
    local authority = self:GetManagedAuthorization(botRef)
    if authority.authorized ~= true then return nil, authority.reason or "TARGET_RESOLVE_REQUIRED" end
    return authority
end

function MB:ResolveManagedKey(botRef)
    if not self.managedStore then return nil end
    if type(botRef) == "number" then
        local key = tostring(math.floor(botRef)); if self.managedStore.entries[key] then return key end
    end
    if type(botRef) == "string" then
        local numeric = tonumber(botRef)
        if numeric and numeric > 0 and self.managedStore.entries[tostring(math.floor(numeric))] then return tostring(math.floor(numeric)) end
    end
    local bot = self:ResolveBot(botRef)
    local guid = managedGuid(bot)
    if guid and self.managedStore.entries[tostring(guid)] then return tostring(guid) end
    local name = type(botRef) == "table" and (botRef.name or botRef.bot or botRef.target) or botRef
    local key = self:BotKey(name)
    return key and self.managedStore.nameIndex[key] or nil
end

local function resolveForgetManagedKey(self, botRef)
    if not self.managedStore then return nil, "MANAGED_STORE_NOT_READY" end

    local explicitGuid, suppliedName
    if type(botRef) == "number" then
        explicitGuid = tonumber(botRef)
    elseif type(botRef) == "table" then
        explicitGuid = tonumber(botRef.guid or botRef.altGuid)
        suppliedName = self:NormalizeName(botRef.name or botRef.bot or botRef.target)
    elseif type(botRef) == "string" then
        local trimmed = self:Trim(botRef)
        if string.match(trimmed, "^%d+$") then explicitGuid = tonumber(trimmed) else suppliedName = self:NormalizeName(trimmed) end
    end

    if explicitGuid and explicitGuid > 0 then
        local guidKey = tostring(math.floor(explicitGuid))
        local entry = self.managedStore.entries[guidKey]
        if not entry then return nil, "MANAGED_BOT_NOT_FOUND" end
        if suppliedName and self:BotKey(entry.name) ~= self:BotKey(suppliedName) then
            return nil, "AMBIGUOUS_IDENTITY"
        end
        return guidKey, nil, entry
    end

    if not suppliedName then return nil, "MANAGED_BOT_REQUIRED" end
    local nameKey = self:BotKey(suppliedName)
    local guidKey = nameKey and self.managedStore.nameIndex[nameKey] or nil
    local entry = guidKey and self.managedStore.entries[guidKey] or nil
    if not entry then return nil, "MANAGED_BOT_NOT_FOUND" end

    -- A name can be reused after a server character is deleted. If the current
    -- session knows the same name with a different stable GUID, refuse a
    -- name-only destructive operation and require the caller to pass the GUID.
    local live = self:ResolveBot(suppliedName)
    local liveGuid = managedGuid(live)
    if liveGuid and tostring(math.floor(liveGuid)) ~= tostring(guidKey) then
        return nil, "AMBIGUOUS_IDENTITY"
    end
    return tostring(guidKey), nil, entry
end

local function currentManagedBotForGuid(self, guidKey, entry)
    local bot = entry and entry.name and self:ResolveBot(entry.name) or nil
    if not bot then return nil end
    local guid = managedGuid(bot)
    if guid and tostring(math.floor(guid)) ~= tostring(guidKey) then return nil end
    return bot
end

local function managedEntryView(self, guidKey, persisted)
    local entry = self:Copy(persisted or {})
    local bot = self:ResolveBot(entry.name)
    local snapshot = self.GetBotSnapshot and select(1, self:GetBotSnapshot(tonumber(guidKey))) or nil
    local authority = self:GetManagedAuthorization(bot or entry.name)
    entry.guid = tonumber(entry.guid) or tonumber(guidKey)
    entry.altRosterPresent = bot and bot.altRosterPresent == true or false
    entry.online = bot and bot.online == true or false
    if bot then
        entry.class = bot.class or entry.class
        entry.classId = tonumber(bot.classId) or entry.classId
        entry.className = bot.className or entry.className
        entry.level = tonumber(bot.level) or entry.level
        entry.race = bot.race or entry.race
    end

    -- Persisted lastKnownLifecycle is historical metadata only. It must never be
    -- promoted to the current/effective state after reload or session reset.
    -- Current state is selected from authorities observed in this bridge session,
    -- preferring the newest observation when lifecycle/roster updates race.
    entry.lastKnownLifecycle = self:Upper(entry.lastKnownLifecycle or "UNKNOWN")
    entry.lifecycleState = entry.lastKnownLifecycle
    entry.effectiveState = "UNKNOWN"
    entry.effectiveStateSource = "NONE"
    entry.effectiveStateObservedAt = nil

    local evidence = {}
    local function addEvidence(state, source, observedAt)
        state = self:Upper(state)
        observedAt = tonumber(observedAt) or 0
        if state ~= "ONLINE" and state ~= "OFFLINE" and state ~= "CONNECTING" and state ~= "DISCONNECTING" then return end
        evidence[#evidence + 1] = { state = state, source = source, observedAt = observedAt }
    end

    if bot then
        if tonumber(bot.lifecycleSessionEpoch) == tonumber(self.sessionEpoch) then
            addEvidence(bot.lifecycleState, bot.lifecycleStateSource or "BOT.LIFECYCLE", bot.lifecycleObservedAt)
        end
        if tonumber(bot.altRosterSessionEpoch) == tonumber(self.sessionEpoch) then
            addEvidence(bot.lifecycleState, "ALT.ROSTER", bot.altRosterObservedAt)
        end
    end

    -- BRIDGE.ROSTER is a current-session presence authority once the registry has
    -- completed for this session. Presence means ONLINE; absence means OFFLINE.
    if self.botRegistryReady == true and tonumber(self.botRegistryReadyEpoch) == tonumber(self.sessionEpoch) then
        local rosterMeta = self:GetDataMeta("BRIDGE.ROSTER")
        if rosterMeta and rosterMeta.stale ~= true then
            addEvidence(entry.online and "ONLINE" or "OFFLINE", "BRIDGE.ROSTER", rosterMeta.updatedAt)
        end
    end

    table.sort(evidence, function(a, b)
        if a.observedAt == b.observedAt then
            local priority = { ["BOT.LIFECYCLE"] = 4, ["BOT_LIFECYCLE"] = 4, ["BOT_LIFECYCLE_STATE"] = 4, ["BOT_LIFECYCLE_PENDING"] = 4, ["BOT_TARGET_RESOLVE"] = 3, ["ALT.ROSTER"] = 2, ["BRIDGE.ROSTER"] = 1 }
            return (priority[a.source] or 0) > (priority[b.source] or 0)
        end
        return a.observedAt > b.observedAt
    end)
    local current = evidence[1]
    if current then
        entry.lifecycleState = current.state
        entry.effectiveState = current.state
        entry.effectiveStateSource = current.source
        entry.effectiveStateObservedAt = current.observedAt
    end
    entry.authorization = authority
    entry.snapshot = snapshot and {
        exists = true, capturedAt = snapshot.capturedAt, profile = snapshot.profile, complete = snapshot.complete == true,
        coreVersion = snapshot.coreVersion,
    } or { exists = false }
    entry.discovery = { sources = self:Copy(entry.sources or {}), altRosterEver = entry.altRosterEver == true }
    return entry
end

function MB:GetManagedBot(botRef)
    local key = self:ResolveManagedKey(botRef)
    if not key or not self.managedStore or not self.managedStore.entries[key] then return nil, "MANAGED_BOT_NOT_FOUND" end
    return managedEntryView(self, key, self.managedStore.entries[key])
end

function MB:GetManagedRosterView()
    local view = { schemaVersion = MANAGED_SCHEMA_VERSION, items = {}, count = 0 }
    if not self.managedStore then return view end
    for guidKey, entry in pairs(self.managedStore.entries or {}) do
        view.items[#view.items + 1] = managedEntryView(self, guidKey, entry)
    end
    table.sort(view.items, function(a, b) return self:Lower(a.name or "") < self:Lower(b.name or "") end)
    view.count = #view.items
    return view
end

function MB:GetForgetManagedBotAvailability(botRef)
    local guidKey, err, entry = resolveForgetManagedKey(self, botRef)
    if not guidKey then return { enabled = false, reason = err or "MANAGED_BOT_NOT_FOUND" } end

    local bot = currentManagedBotForGuid(self, guidKey, entry)
    local state = bot and self:Upper(bot.lifecycleState) or "UNKNOWN"
    if bot and (bot.online == true or bot.altOnline == true or state == "ONLINE" or state == "CONNECTING" or state == "DISCONNECTING") then
        return { enabled = false, reason = "BOT_ONLINE", guid = tonumber(guidKey), name = entry.name, lifecycleState = state }
    end

    local snapshotBusy = self.snapshotActiveByGuid and self.snapshotActiveByGuid[tonumber(guidKey)]
    if snapshotBusy then
        return { enabled = false, reason = "SNAPSHOT_BUSY", guid = tonumber(guidKey), name = entry.name, requestId = snapshotBusy }
    end

    local groupBusy = self.managedGroupLifecycleGuidReservations and self.managedGroupLifecycleGuidReservations[guidKey]
    if groupBusy then
        return { enabled = false, reason = "GROUP_MEMBER_BUSY", guid = tonumber(guidKey), name = entry.name, requestId = groupBusy }
    end

    return { enabled = true, guid = tonumber(guidKey), guidKey = guidKey, name = entry.name, onlinePolicy = "REFUSE_WHILE_ONLINE" }
end

function MB:ForgetManagedBot(originModule, botRef, options, callback)
    originModule = self:Trim(originModule)
    options = type(options) == "table" and options or {}
    local availability = self:GetForgetManagedBotAvailability(botRef)
    if availability.enabled ~= true then
        local result = {
            ok = false, status = "REFUSED", code = availability.reason or "MANAGED_BOT_NOT_FOUND",
            originModule = originModule ~= "" and originModule or nil,
            guid = availability.guid, name = availability.name,
        }
        if type(callback) == "function" then self:SafeCall(callback, self:Copy(result)) end
        return result
    end

    local guidKey = tostring(availability.guidKey)
    local entry = self.managedStore.entries[guidKey]
    if type(entry) ~= "table" then
        local result = { ok = false, status = "REFUSED", code = "MANAGED_BOT_NOT_FOUND", originModule = originModule ~= "" and originModule or nil }
        if type(callback) == "function" then self:SafeCall(callback, self:Copy(result)) end
        return result
    end
    local name = entry.name
    local oldEntry = self:Copy(entry)

    -- Cascade only Core-owned persistent state associated with this stable GUID.
    -- Groups are updated while the managed identity still exists so group views
    -- can carry the friendly member name in their emitted update event.
    local groupsRemoved, groupIds = 0, {}
    if self.ForgetManagedBotFromGroups then groupsRemoved, groupIds = self:ForgetManagedBotFromGroups(guidKey) end
    local snapshotsRemoved = self.ForgetSnapshotForManagedBot and self:ForgetSnapshotForManagedBot(guidKey, name) or 0
    local liveByName = name and self:ResolveBot(name) or nil
    local liveByNameGuid = managedGuid(liveByName)
    local clearNamePending = not liveByNameGuid or tostring(math.floor(liveByNameGuid)) == guidKey
    local lastKnownRemoved = self.ForgetLastKnownForManagedBot and self:ForgetLastKnownForManagedBot(guidKey, name, clearNamePending) or 0

    if self.managedSessionAuthByGuid then self.managedSessionAuthByGuid[tonumber(guidKey)] = nil end
    local nameKey = self:BotKey(name)
    if nameKey and self.managedStore.nameIndex[nameKey] == guidKey then self.managedStore.nameIndex[nameKey] = nil end
    self.managedStore.entries[guidKey] = nil

    -- Do not delete or reinterpret the live registry. Only clear the two markers
    -- that were projected into the session registry from the persistent store.
    local bot = name and self:ResolveBot(name) or nil
    if bot and managedGuid(bot) and tostring(math.floor(managedGuid(bot))) == guidKey then
        bot.managedKnown = false
        bot.managedPersisted = false
    end

    local result = {
        ok = true, status = "CONFIRMED", code = "MANAGED_BOT_FORGOTTEN",
        originModule = originModule ~= "" and originModule or nil,
        guid = tonumber(guidKey), name = name, forgottenAt = epochNow(),
        cleanup = {
            managedRoster = 1, lastKnown = tonumber(lastKnownRemoved) or 0, snapshots = tonumber(snapshotsRemoved) or 0,
            groups = tonumber(groupsRemoved) or 0, groupIds = self:Copy(groupIds or {}),
        },
        rediscoveryAllowed = true, serverCharacterAffected = false, accountLinkAffected = false,
        oldEntry = options.includePrevious == true and oldEntry or nil,
    }
    self:Emit("MB_MANAGED_BOT_FORGOTTEN", guidKey, name, self:Copy(result))
    if type(callback) == "function" then self:SafeCall(callback, self:Copy(result)) end
    return result
end

function MB:GetManagedLifecycleAvailability(botRef, action)
    action = self:Upper(action)
    if action ~= "CONNECT" and action ~= "DISCONNECT" then return { enabled = false, reason = "INVALID_LIFECYCLE_ACTION", action = action } end
    if not self.bridge.connected then return { enabled = false, reason = "BRIDGE_NOT_CONNECTED", action = action } end
    if not self.bridge.handshakeReady or self.bridge.capabilitiesResolved ~= true then return { enabled = false, reason = "BRIDGE_NOT_READY", action = action } end
    if not self:BridgeHasCapability("BOT_LIFECYCLE_V1") then return { enabled = false, reason = "CAPABILITY_UNAVAILABLE", action = action } end
    local bot = self:ResolveBot(botRef)
    local name = bot and bot.name or self:NormalizeName(type(botRef) == "table" and (botRef.name or botRef.bot or botRef.target) or botRef)
    if not name then return { enabled = false, reason = "BOT_REQUIRED", action = action } end
    local authority = self:GetManagedAuthorization(bot or name)
    if authority.authorized and authority.source == "ALT_ROSTER" then
        return {
            enabled = true, reason = nil, action = action, botName = name, requiresResolve = false, requiresAltRefresh = true,
            preflight = "ALT.ROSTER", authority = authority,
        }
    end
    -- Non-ALT targets always resolve inside the orchestrated lifecycle request,
    -- even if another caller obtained a short-lived proof moments ago. Persisted
    -- identity and unrelated prior resolves must never become implicit authority.
    if not self:BridgeHasCapability("BOT_TARGET_RESOLVE_V1") then
        return { enabled = false, reason = "CAPABILITY_UNAVAILABLE", action = action, botName = name, requiresResolve = true }
    end
    return {
        enabled = true, reason = nil, action = action, botName = name, requiresResolve = true,
        preflight = "BOT_TARGET_RESOLVE", authority = { authorized = false, source = "RESOLVE_REQUIRED", sessionBound = true },
    }
end
