local _, MB = ...

function MB:BridgeHasCapability(capability)
    return self.bridge
        and self.bridge.capabilitiesResolved == true
        and self.bridge.capabilities
        and self.bridge.capabilities[self:Trim(capability)] == true
end

function MB:SetBridgeConnected(connected, reason)
    connected = connected == true
    local changed = self.bridge.connected ~= connected
    self.bridge.connected = connected
    if reason then self.bridge.lastError = reason end
    if changed then
        self:Emit("MB_BRIDGE_STATUS_CHANGED", connected, reason, self.bridge.server, self.bridge.protocol)
    end
end

function MB:BridgeSend(opcode, payload)
    if not self.db or not self.db.enabled or not self.db.bridge.enabled then return false, "BRIDGE_DISABLED" end
    if type(SendAddonMessage) ~= "function" then return false, "SEND_ADDON_MESSAGE_UNAVAILABLE" end
    local playerName = type(UnitName) == "function" and UnitName("player") or nil
    if not playerName or playerName == "" then return false, "PLAYER_NAME_UNAVAILABLE" end

    opcode = self:Trim(opcode)
    if opcode == "" then return false, "OPCODE_REQUIRED" end
    local message = opcode
    if payload ~= nil and payload ~= "" then message = message .. "~" .. tostring(payload) end

    local channel = "WHISPER"
    if type(GetNumRaidMembers) == "function" and (GetNumRaidMembers() or 0) > 0 then
        channel = "RAID"
    elseif type(GetNumPartyMembers) == "function" and (GetNumPartyMembers() or 0) > 0 then
        channel = "PARTY"
    end

    if channel == "WHISPER" then SendAddonMessage(self.BRIDGE_PREFIX, message, channel, playerName)
    else SendAddonMessage(self.BRIDGE_PREFIX, message, channel) end

    self.bridge.lastTxAt = self:Now()
    self.runtime.counters.bridgeTx = self.runtime.counters.bridgeTx + 1
    self:Log("DEBUG", "Bridge TX %s %s", opcode, tostring(payload or ""))
    return true
end

function MB:BridgeHello()
    self.bridge.lastHelloAt = self:Now()
    self.bridge.bootstrapPending = true
    return self:BridgeSend("HELLO", self.PROTOCOL_VERSION)
end

function MB:BridgePing()
    local token = self:NewToken("ping")
    self.bridge.lastPingAt = self:Now()
    self.bridge.lastPingToken = token
    return self:BridgeSend("PING", token)
end

function MB:ResetBridgeSession(reason)
    reason = reason or "SESSION_RESET"
    local wasConnected = self.bridge.connected

    -- Close the transport gate before notifying pending callbacks. A callback triggered by
    -- SESSION_RESET must not be able to dispatch fresh work into the session being torn down.
    self.bridge.connected = false
    self.bridge.bootstrapPending = false
    self.bridge.handshakeReady = false

    local abortedReads = self.AbortPendingReads and self:AbortPendingReads(reason) or 0
    if self.ResetEquipmentObservationSession then self:ResetEquipmentObservationSession(reason) end
    if self.ResetSpellCompatibilitySession then self:ResetSpellCompatibilitySession(reason) end
    local abortedActions = self.AbortPendingActions and self:AbortPendingActions(reason) or 0
    if self.AbortManagedLifecycleRequests then self:AbortManagedLifecycleRequests("BRIDGE_SESSION_CHANGED") end
    if abortedReads > 0 or abortedActions > 0 then
        self:Log("INFO", "Bridge session reset aborted reads=%d actions=%d reason=%s", abortedReads, abortedActions, tostring(reason))
    end
    self.bridge.protocol = nil
    self.bridge.server = nil
    self.bridge.capabilities = {}
    self.bridge.capabilityBatchActive = false
    self.bridge.capabilitiesResolved = false
    self.bridge.frames = {}
    self.bridge.altRosterBatch = nil
    self.bridge.actionTokens = {}
    self.bridge.stateGlobalLatestToken = nil
    self.bridge.lastBootstrapAt = nil
    self.bridge.bootstrapBurstId = (tonumber(self.bridge.bootstrapBurstId) or 0) + 1
    self.botRegistryReady = false
    self.botRegistryReadyEpoch = 0
    if self.ResetTacticalSessionState then self:ResetTacticalSessionState(reason) end
    if self.ResetManagedSessionState then self:ResetManagedSessionState(reason) end
    if self.ResetLastKnownSessionState then self:ResetLastKnownSessionState(reason) end
    self.bridge.lastError = reason
    if wasConnected then self:Emit("MB_BRIDGE_STATUS_CHANGED", false, reason) end
end

function MB:StartBridgeSession(reason)
    if not self.db or not self.db.enabled or not self.db.bridge.enabled then return end

    -- PLAYER_ENTERING_WORLD starts a new authoritative bridge session. Do not let
    -- a previous zone/session's connected/protocol state make bootstrap GETs look ready.
    self:ResetBridgeSession(reason or "SESSION_RESTART")
    self.sessionEpoch = (self.sessionEpoch or 0) + 1
    self.bridge.bootstrapPending = true
    self:Emit("MB_SESSION_CHANGED", self.sessionEpoch, reason or "START")
    self:BridgeHello()
    self:BridgePing()

    -- Retry the handshake if HELLO_ACK is delayed/lost. Discovery itself is deliberately
    -- post-handshake; HELLO_ACK schedules the authoritative bootstrap below.
    local delay = math.max(0.50, tonumber(self.db.bridge.bootstrapDelay) or 0.4)
    self:After(delay, function()
        if not (MB.initialized and MB.db and MB.db.enabled and MB.db.bridge.enabled) then return end
        if MB.bridge.handshakeReady and MB.bridge.connected then
            MB:BridgeBootstrap("SESSION_READY")
        elseif MB.bridge.bootstrapPending then
            MB:BridgeHello()
            MB:BridgePing()
        end
    end)
end

local function dispatchBootstrapSnapshot(self, epoch, burstId, label)
    if not (self.initialized and self.db and self.db.enabled and self.db.bridge.enabled) then return false end
    if self.sessionEpoch ~= epoch then return false end
    if not (self.bridge.connected and self.bridge.handshakeReady and self.bridge.protocol) then return false end
    if tonumber(self.bridge.bootstrapBurstId) ~= tonumber(burstId) then return false end

    self:Log("DEBUG", "Bridge bootstrap snapshot: %s", tostring(label or "snapshot"))
    self:BridgeRequestRoster()
    self:BridgeRequestStates()
    self:BridgeRequestDetails()
    return true
end

function MB:BridgeBootstrap(reason)
    -- Mirror the bridge developer client's stabilization behavior: one immediate
    -- roster/state/details snapshot followed by snapshots at ~0.8s and ~2.0s.
    -- Bots can become visible to the bridge shortly after login/group formation, so
    -- a single successful but empty ROSTER must not be treated as the only discovery pass.
    if not self.bridge.connected or not self.bridge.handshakeReady or not self.bridge.protocol then
        return false, "BRIDGE_HANDSHAKE_INCOMPLETE"
    end
    local now = self:Now()
    if self.bridge.lastBootstrapAt and now - self.bridge.lastBootstrapAt < 1.00 then return false, "BOOTSTRAP_DEDUPED" end
    self.bridge.lastBootstrapAt = now
    self.bridge.bootstrapBurstId = (tonumber(self.bridge.bootstrapBurstId) or 0) + 1
    local burstId = self.bridge.bootstrapBurstId
    local epoch = self.sessionEpoch
    self:Log("DEBUG", "Bridge bootstrap burst: %s id=%s", tostring(reason or "manual"), tostring(burstId))

    dispatchBootstrapSnapshot(self, epoch, burstId, "immediate")
    self:After(0.80, function() dispatchBootstrapSnapshot(MB, epoch, burstId, "0.8s") end)
    self:After(2.00, function() dispatchBootstrapSnapshot(MB, epoch, burstId, "2.0s") end)
    return true
end

function MB:ObserveProtocolExtension(opcode, payload)
    opcode = self:Trim(opcode)
    if opcode == "" then return end
    local first = self.bridge.observedExtensions[opcode] == nil
    local entry = self.bridge.observedExtensions[opcode] or { count = 0, firstSeenAt = self:Now() }
    entry.count = entry.count + 1
    entry.lastSeenAt = self:Now()
    entry.sample = string.sub(tostring(payload or ""), 1, 220)
    self.bridge.observedExtensions[opcode] = entry
    if first then self:Emit("MB_PROTOCOL_EXTENSION_OBSERVED", opcode, self:Copy(entry)) end
end

function MB:HandleBridgeAddonMessage(prefix, message, distribution, sender)
    if prefix ~= self.BRIDGE_PREFIX then return false end
    message = tostring(message or "")
    local opcode, payload = self:SplitOnce(message, "~")
    opcode = self:Upper(opcode)
    self.bridge.lastRxAt = self:Now()
    self.runtime.counters.bridgeRx = self.runtime.counters.bridgeRx + 1
    self:Log("DEBUG", "Bridge RX %s %s", opcode, tostring(payload or ""))
    if self.ProtocolHandle then
        local handled = self:ProtocolHandle(opcode, payload, distribution, sender)
        if handled then return true end
    end
    if self.db and self.db.diagnostics and self.db.diagnostics.observeUnknownProtocol then self:ObserveProtocolExtension(opcode, payload) end
    return false
end
