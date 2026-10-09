local addonName, MB = ...

local LEGACY_PROFILE_MIGRATION_KEY = "__elvuiProfileMigrationVersion"
local LEGACY_PROFILE_MIGRATION_VERSION = 1

local function activeElvUIProfile()
    if MB.E and MB.E.data and type(MB.E.data.profile) == "table" then return MB.E.data.profile end
    if MB.E and type(MB.E.db) == "table" then return MB.E.db end
    return nil
end

local function legacyProfilePayload(saved)
    if type(saved) ~= "table" then return nil end
    local payload = {}
    local hasValue = false
    for key in pairs(MB.defaults or {}) do
        if saved[key] ~= nil then
            payload[key] = MB:Copy(saved[key])
            hasValue = true
        end
    end
    return hasValue and payload or nil
end

function MB:BindElvUIProfileDatabase(migrateLegacy)
    local profile = activeElvUIProfile()
    if not profile then return false, "ELVUI_PROFILE_NOT_READY" end

    local db = profile.multibotCore
    if type(db) ~= "table" then
        db = self:Copy(self.defaults)
        profile.multibotCore = db
    end

    if migrateLegacy == true then
        local saved = _G.ElvUI_Multibot_CoreDB
        if type(saved) ~= "table" then
            saved = {}
            _G.ElvUI_Multibot_CoreDB = saved
        end
        if tonumber(saved[LEGACY_PROFILE_MIGRATION_KEY]) ~= LEGACY_PROFILE_MIGRATION_VERSION then
            local payload = legacyProfilePayload(saved)
            if payload then self:Merge(db, payload) end
            saved[LEGACY_PROFILE_MIGRATION_KEY] = LEGACY_PROFILE_MIGRATION_VERSION
        end
    end

    self.db = db
    return true
end

function MB:OnElvUIProfileChanged()
    local ok, reason = self:BindElvUIProfileDatabase(false)
    if not ok then
        self:Log("ERROR", "Unable to bind ElvUI profile after profile change: %s", tostring(reason))
    end
end

function MB:RegisterElvUIProfileCallbacks()
    if self.profileCallbacksRegistered then return true end
    local data = self.E and self.E.data
    if not data or type(data.RegisterCallback) ~= "function" then return false, "ELVUI_PROFILE_CALLBACKS_UNAVAILABLE" end

    data.RegisterCallback(self, "OnProfileChanged", "OnElvUIProfileChanged")
    data.RegisterCallback(self, "OnProfileCopied", "OnElvUIProfileChanged")
    data.RegisterCallback(self, "OnProfileReset", "OnElvUIProfileChanged")
    self.profileCallbacksRegistered = true
    return true
end

function MB:Initialize()
    if self.initialized then return true end
    if not (self.E and self.E.data and self.E.db) then return false, "ELVUI_NOT_INITIALIZED" end

    local dbOK, dbReason = self:BindElvUIProfileDatabase(true)
    if not dbOK then return false, dbReason end
    self:RegisterElvUIProfileCallbacks()
    if self.InitializeSnapshotStore then self:InitializeSnapshotStore() end
    if self.InitializeManagedRosterStore then self:InitializeManagedRosterStore() end
    if self.InitializeLastKnownStore then self:InitializeLastKnownStore() end
    if self.InitializeManagedGroupStore then self:InitializeManagedGroupStore() end
    self.initialized = true
    if self.InitializeSelections then self:InitializeSelections() end

    SLASH_ELVUIMULTIBOTCORE1 = "/mbcore"
    SLASH_ELVUIMULTIBOTCORE2 = "/multibotcore"
    SlashCmdList.ELVUIMULTIBOTCORE = function(input) MB:HandleSlash(input) end
    SLASH_ELVUIMULTIBOTCASTGUID1 = "/mbcastguid"
    SlashCmdList.ELVUIMULTIBOTCASTGUID = function(input) if MB.HandleBotSpellMacroSlash then MB:HandleBotSpellMacroSlash(input) end end

    local optionsOK, optionsReason = self:RegisterElvUIOptionsPlugin()
    if not optionsOK then self:Log("WARN", "ElvUI options plugin registration unavailable: %s", tostring(optionsReason)) end

    self:Emit("MB_CORE_READY", self.version, self.API_VERSION)
    self:Log("INFO", "Initialized %s", self.version)
    return true
end

function MB:OnEvent(event, ...)
    if event == "PLAYER_ENTERING_WORLD" then
        self:StartBridgeSession("PLAYER_ENTERING_WORLD")
    elseif event == "CHAT_MSG_ADDON" then
        local prefix, message, distribution, sender = ...
        self:HandleBridgeAddonMessage(prefix, message, distribution, sender)
    elseif event == "CHAT_MSG_WHISPER" then
        local message, author = ...
        if self.HandleQuestWhisper then self:HandleQuestWhisper(message, author) end
        if self.HandleSpellCompatibilityWhisper then self:HandleSpellCompatibilityWhisper(message, author) end
    elseif event == "TRADE_SHOW" then
        if self.HandleTradeShow then self:HandleTradeShow() end
    elseif event == "TRADE_CLOSED" then
        if self.HandleTradeClosed then self:HandleTradeClosed() end
    elseif event == "INSPECT_READY" then
        if self.OnInspectReady then self:OnInspectReady(...) end
    elseif event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
        self:After(0.25, function()
            if MB.bridge.connected or MB.bridge.bootstrapPending then MB:BridgeBootstrap(event) end
        end)
    end
end

function MB:OnUpdate(elapsed)
    if not self.db or not self.db.enabled then return end
    self:RunTimers()
    self._schedulerElapsed = (self._schedulerElapsed or 0) + (elapsed or 0)
    self._timeoutElapsed = (self._timeoutElapsed or 0) + (elapsed or 0)
    self._heartbeatElapsed = (self._heartbeatElapsed or 0) + (elapsed or 0)

    if self._schedulerElapsed >= 0.25 then
        self._schedulerElapsed = 0
        self:RunDataScheduler()
    end
    if self._timeoutElapsed >= 0.20 then
        self._timeoutElapsed = 0
        self:RunReadTimeouts()
        self:RunActionTimeouts()
    end
    if self._heartbeatElapsed >= 1.0 then
        self._heartbeatElapsed = 0
        local now = self:Now()
        if self.db.bridge.enabled then
            if self.bridge.connected then
                if now - (self.bridge.lastPingAt or 0) >= (tonumber(self.db.bridge.heartbeatInterval) or 15) then self:BridgePing() end
                local lastRx = tonumber(self.bridge.lastRxAt) or 0
                if lastRx > 0 and now - lastRx >= (tonumber(self.db.bridge.disconnectTimeout) or 35) then
                    self:StartBridgeSession("HEARTBEAT_TIMEOUT")
                end
            elseif self.bridge.bootstrapPending then
                local retry = math.max(2, tonumber(self.db.bridge.handshakeRetryInterval) or 5)
                if now - (self.bridge.lastHelloAt or 0) >= retry then
                    self:BridgeHello()
                    self:BridgePing()
                end
            end
        end
    end
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("CHAT_MSG_ADDON")
eventFrame:RegisterEvent("PARTY_MEMBERS_CHANGED")
eventFrame:RegisterEvent("RAID_ROSTER_UPDATE")
eventFrame:RegisterEvent("CHAT_MSG_WHISPER")
eventFrame:RegisterEvent("TRADE_SHOW")
eventFrame:RegisterEvent("TRADE_CLOSED")
local inspectEventOK = pcall(eventFrame.RegisterEvent, eventFrame, "INSPECT_READY")
if MB.SetEquipmentInspectEventRegistered then MB:SetEquipmentInspectEventRegistered(inspectEventOK) end
eventFrame:SetScript("OnEvent", function(_, event, ...)
    if MB.initialized then MB:OnEvent(event, ...) end
end)
eventFrame:SetScript("OnUpdate", function(_, elapsed)
    if MB.initialized then MB:OnUpdate(elapsed) end
end)
MB.eventFrame = eventFrame

-- ElvUI 6.09 creates E.data/E.db inside E:Initialize(). Register a post-initialize
-- hook instead of treating this addon's ADDON_LOADED as an ElvUI-ready signal.
local EP = LibStub and LibStub("LibElvUIPlugin-1.0", true)
if MB.E and MB.E.data and MB.E.db then
    MB:Initialize() -- supports an unusual late/manual load after ElvUI is already ready
elseif EP and type(EP.HookInitialize) == "function" then
    EP:HookInitialize(MB, "Initialize")
else
    error("ElvUI_Multibot_Core requires ElvUI 6.09 with LibElvUIPlugin-1.0")
end
