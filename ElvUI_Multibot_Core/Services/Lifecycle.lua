local _, MB = ...

local TARGET_RESOLVE_TIMEOUT = 5
local LIFECYCLE_TIMEOUT = 12
local LIFECYCLE_POLL_INTERVAL = 1

local function normalizeLifecycleState(self, value)
    local state = self:Upper(value)
    if state == "ONLINE" or state == "OFFLINE" or state == "CONNECTING" or state == "DISCONNECTING" then return state end
    return "UNKNOWN"
end

local function lifecycleActionFromId(actionId)
    if actionId == "BOT.CONNECT" then return "CONNECT" end
    if actionId == "BOT.DISCONNECT" then return "DISCONNECT" end
    return nil
end

local function actionFinalState(action)
    return action == "CONNECT" and "ONLINE" or "OFFLINE"
end

local function actionFallbackState(action)
    return action == "CONNECT" and "OFFLINE" or "ONLINE"
end

function MB:GetAltRosterView()
    local value, meta = self:GetData("ALT.ROSTER")
    if type(value) ~= "table" then return value, meta end
    local view = self:Copy(value)
    for _, entry in ipairs(view.items or {}) do
        local bot = self:ResolveBot(entry.name)
        local transient = bot and normalizeLifecycleState(self, bot.lifecycleState) or "UNKNOWN"
        if transient == "CONNECTING" or transient == "DISCONNECTING" then
            entry.effectiveState = transient
        else
            entry.effectiveState = normalizeLifecycleState(self, entry.state)
        end
    end
    return view, meta
end

function MB:GetLifecycleTargetView(botRef)
    return self:GetData("BOT.LIFECYCLE_TARGET", botRef)
end

function MB:ResolveBotTarget(botRef, callback)
    local bot = self:ResolveBot(botRef)
    local name = bot and bot.name or self:NormalizeName(type(botRef) == "table" and (botRef.name or botRef.bot or botRef.target) or botRef)
    if not name then return nil, "BOT_REQUIRED" end
    if not self.bridge.connected then return nil, "BRIDGE_NOT_CONNECTED" end
    if not self.bridge.handshakeReady or self.bridge.capabilitiesResolved ~= true then return nil, "BRIDGE_NOT_READY" end
    if not self:BridgeHasCapability("BOT_TARGET_RESOLVE_V1") then return nil, "CAPABILITY_UNAVAILABLE" end
    return self:RefreshDomain("BOT.LIFECYCLE_TARGET", name, callback, { timeout = TARGET_RESOLVE_TIMEOUT })
end

function MB:GetBotLifecycleAvailability(botRef, action)
    action = self:Upper(action)
    local actionId = action == "CONNECT" and "BOT.CONNECT" or (action == "DISCONNECT" and "BOT.DISCONNECT" or nil)
    if not actionId then return { enabled = false, reason = "INVALID_LIFECYCLE_ACTION", action = action } end
    return self:GetActionAvailability(actionId, botRef, { scope = "BOT" })
end

function MB:ExecuteBotLifecycle(originModule, botRef, action, callback)
    action = self:Upper(action)
    local actionId = action == "CONNECT" and "BOT.CONNECT" or (action == "DISCONNECT" and "BOT.DISCONNECT" or nil)
    if not actionId then return nil, "INVALID_LIFECYCLE_ACTION" end
    return self:ExecuteAction(originModule, actionId, botRef, { scope = "BOT" }, callback)
end


local function emitLifecycleRequestResult(self, request, status, code, tx)
    local result = {
        requestId = request.id, status = status, ok = status == "COMPLETED" and tx and tx.state == "CONFIRMED",
        code = code, action = request.action, botName = request.botName, guid = request.guid,
        authority = request.authority, transaction = tx and self:Copy(tx) or nil,
    }
    self.lifecycleRequests[request.id] = nil
    self:Emit("MB_BOT_LIFECYCLE_REQUEST_RESULT", self:Copy(result))
    if type(request.callback) == "function" then self:SafeCall(request.callback, self:Copy(result)) end
    return result
end

function MB:AbortManagedLifecycleRequests(reason)
    if self.AbortManagedGroupLifecycleRequests then self:AbortManagedGroupLifecycleRequests(reason or "BRIDGE_SESSION_CHANGED") end
    local pending = {}
    for _, request in pairs(self.lifecycleRequests or {}) do pending[#pending + 1] = request end
    for _, request in ipairs(pending) do
        if self.lifecycleRequests[request.id] then
            emitLifecycleRequestResult(self, request, "REFUSED", reason or "BRIDGE_SESSION_CHANGED")
        end
    end
    self.lifecycleRequests = {}
end

function MB:RequestBotLifecycle(originModule, botRef, action, callback)
    action = self:Upper(action)
    if action ~= "CONNECT" and action ~= "DISCONNECT" then return nil, "INVALID_LIFECYCLE_ACTION" end
    local availability = self:GetManagedLifecycleAvailability(botRef, action)
    if not availability or availability.enabled ~= true then return nil, availability and availability.reason or "LIFECYCLE_UNAVAILABLE" end
    local bot = self:ResolveBot(botRef)
    local name = bot and bot.name or self:NormalizeName(type(botRef) == "table" and (botRef.name or botRef.bot or botRef.target) or botRef)
    if not name then return nil, "BOT_REQUIRED" end

    self.lifecycleRequestSequence = (self.lifecycleRequestSequence or 0) + 1
    local request = {
        id = "lifecycle-request-" .. tostring(self.lifecycleRequestSequence), originModule = originModule,
        botName = name, action = action, callback = callback, sessionEpoch = self.sessionEpoch,
        authority = availability.authority and availability.authority.source or nil,
    }
    self.lifecycleRequests[request.id] = request

    local function dispatchWithCurrentAuthority()
        if request.sessionEpoch ~= MB.sessionEpoch or not MB.bridge.connected then
            emitLifecycleRequestResult(MB, request, "REFUSED", "BRIDGE_SESSION_CHANGED")
            return
        end
        local liveBot = MB:ResolveBot(request.botName)
        local direct = MB:GetBotLifecycleAvailability(liveBot or request.botName, request.action)
        if not direct or direct.enabled ~= true then
            emitLifecycleRequestResult(MB, request, "REFUSED", direct and direct.reason or "LIFECYCLE_UNAVAILABLE")
            return
        end
        request.guid = direct.normalizedArgs and direct.normalizedArgs.guid or (liveBot and (liveBot.guid or liveBot.altGuid))
        request.authority = direct.normalizedArgs and direct.normalizedArgs.lifecycleAuthority or request.authority
        local txId, err = MB:ExecuteBotLifecycle(request.originModule, request.botName, request.action, function(tx)
            emitLifecycleRequestResult(MB, request, "COMPLETED", tx and (tx.error or tx.state) or "UNKNOWN", tx)
        end)
        if not txId then emitLifecycleRequestResult(MB, request, "REFUSED", err or "LIFECYCLE_DISPATCH_FAILED") end
    end

    if availability.requiresAltRefresh == true then
        local readId, err = self:RefreshDomain("ALT.ROSTER", nil, function(_, meta)
            if request.sessionEpoch ~= MB.sessionEpoch or not MB.bridge.connected then
                emitLifecycleRequestResult(MB, request, "REFUSED", "BRIDGE_SESSION_CHANGED")
                return
            end
            if meta and meta.status == "ERROR" then
                emitLifecycleRequestResult(MB, request, "REFUSED", meta.error or "ALT_ROSTER_REFRESH_FAILED")
                return
            end
            MB:After(0, dispatchWithCurrentAuthority)
        end)
        if not readId then
            self.lifecycleRequests[request.id] = nil
            return nil, err or "ALT_ROSTER_REFRESH_FAILED"
        end
        request.altRosterReadId = readId
        return request.id, "REFRESHING_ALT_ROSTER"
    elseif availability.requiresResolve ~= true then
        dispatchWithCurrentAuthority()
        return request.id, "DIRECT"
    end

    local readId, err = self:ResolveBotTarget(name, function(value, meta)
        if request.sessionEpoch ~= MB.sessionEpoch or not MB.bridge.connected then
            emitLifecycleRequestResult(MB, request, "REFUSED", "BRIDGE_SESSION_CHANGED")
            return
        end
        if meta and meta.status == "ERROR" then
            emitLifecycleRequestResult(MB, request, "REFUSED", meta.error or "TARGET_RESOLVE_FAILED")
            return
        end
        if type(value) ~= "table" or MB:Upper(value.status) ~= "OK" then
            emitLifecycleRequestResult(MB, request, "REFUSED", type(value) == "table" and value.reason or "TARGET_RESOLVE_FAILED")
            return
        end
        request.botName = value.name or request.botName
        request.guid = tonumber(value.guid)
        request.authority = "BOT_TARGET_RESOLVE"
        local state = MB:Upper(value.lifecycleState)
        if request.action == "CONNECT" and state == "ONLINE" then
            emitLifecycleRequestResult(MB, request, "REFUSED", "ALREADY_ONLINE")
            return
        elseif request.action == "DISCONNECT" and state == "OFFLINE" then
            emitLifecycleRequestResult(MB, request, "REFUSED", "ALREADY_OFFLINE")
            return
        elseif state ~= "ONLINE" and state ~= "OFFLINE" then
            emitLifecycleRequestResult(MB, request, "REFUSED", "LIFECYCLE_BUSY")
            return
        end
        MB:After(0, dispatchWithCurrentAuthority)
    end)
    if not readId then
        self.lifecycleRequests[request.id] = nil
        return nil, err or "TARGET_RESOLVE_DISPATCH_FAILED"
    end
    request.resolveReadId = readId
    return request.id, "RESOLVING"
end

function MB:GetBotLifecycleContract()
    return {
        implemented = true,
        route = "BRIDGE_NATIVE",
        capabilities = { "BOT_LIFECYCLE_V1" },
        altRosterCapability = "ALT_ROSTER_V1",
        targetResolveCapability = "BOT_TARGET_RESOLVE_V1",
        addressing = "ALT_ROSTER_GUID_OR_FRESH_TARGET_RESOLVE_GUID",
        linkedAccountSupport = "TARGET_RESOLVE_AUTHORIZED",
        targetResolve = "BOT.LIFECYCLE_TARGET",
        timeoutSeconds = LIFECYCLE_TIMEOUT,
        pollSeconds = LIFECYCLE_POLL_INTERVAL,
        intermediateStates = { "CONNECTING", "DISCONNECTING" },
        finalStates = { "ONLINE", "OFFLINE" },
        retryAfterSend = false,
        chatFallbackAfterSend = false,
    }
end

function MB:ApplyLifecycleTransient(guid, name, lifecycleState, source)
    guid = tonumber(guid)
    lifecycleState = normalizeLifecycleState(self, lifecycleState)
    if not guid or guid <= 0 or lifecycleState == "UNKNOWN" then return nil end
    local bot = self:ResolveBot(name)
    if not bot then
        local roster = self:GetData("ALT.ROSTER")
        for _, entry in ipairs(type(roster) == "table" and roster.items or {}) do
            if tonumber(entry.guid) == guid then bot = self:ResolveBot(entry.name); name = entry.name; break end
        end
    end
    if name and name ~= "" then
        bot = self:UpsertBot(name, {
            guid = guid,
            lifecycleState = lifecycleState,
            altOnline = lifecycleState == "ONLINE",
            lifecycleSessionEpoch = self.sessionEpoch,
            lifecycleObservedAt = self:Now(),
            lifecycleStateSource = source or "BOT.LIFECYCLE",
        }, source or "BOT.LIFECYCLE")
    end
    if self.RecordManagedLifecycleState and name and name ~= "" then self:RecordManagedLifecycleState(guid, name, lifecycleState, source or "BOT.LIFECYCLE") end
    self:Emit("MB_BOT_LIFECYCLE_UPDATED", guid, name, lifecycleState, source or "BOT.LIFECYCLE")
    return bot
end

function MB:RefreshLifecycleAuthorities(botName)
    self:After(0.10, function()
        if MB.bridge.connected then MB:RefreshDomain("BRIDGE.ROSTER") end
    end)
    self:After(0.20, function()
        if MB.bridge.connected and MB:BridgeHasCapability("ALT_ROSTER_V1") then MB:RefreshDomain("ALT.ROSTER") end
    end)
    if botName and botName ~= "" then
        self:After(0.30, function()
            if MB.bridge.connected and MB:BridgeHasCapability("BOT_TARGET_RESOLVE_V1") then
                MB:RefreshDomain("BOT.LIFECYCLE_TARGET", botName, nil, { timeout = TARGET_RESOLVE_TIMEOUT })
            end
        end)
    end
end

local function clearLifecycleReservation(self, tx)
    if not tx then return end
    if tx.lifecycleGuid and self.lifecycleByGuid and self.lifecycleByGuid[tonumber(tx.lifecycleGuid)] == tx.id then
        self.lifecycleByGuid[tonumber(tx.lifecycleGuid)] = nil
    end
    if tx.bridgeToken then self.bridge.actionTokens[tx.bridgeToken] = nil end
end

function MB:FinalizeBotLifecycle(tx, result, success)
    if type(tx) ~= "table" then return false end
    clearLifecycleReservation(self, tx)
    tx.result = self:Copy(result or {})
    tx.completedAt = self:Now()
    self.runtime.counters.actionsCompleted = self.runtime.counters.actionsCompleted + 1
    if result and result.lifecycleState then
        self:ApplyLifecycleTransient(result.guid, result.name, result.lifecycleState, result.proof or "BOT.LIFECYCLE")
    end
    if success then
        self:SetTransactionState(tx, "CONFIRMED")
        self:ApplyActionInvalidation(tx, result)
    else
        local reason = self:Trim(result and result.reason)
        if reason == "" then reason = "LIFECYCLE_FAILED" end
        self:SetTransactionState(tx, "FAILED", { error = reason })
    end
    self:RefreshLifecycleAuthorities(result and result.name or (tx.targets and tx.targets[1] and tx.targets[1].name))
    if type(tx.callback) == "function" then self:SafeCall(tx.callback, self:TransactionSnapshot(tx)) end
    return true
end

function MB:ScheduleBotLifecyclePoll(tx)
    if type(tx) ~= "table" or tx.lifecyclePolling ~= true then return end
    local txId, epoch = tx.id, tx.sessionEpoch
    self:After(LIFECYCLE_POLL_INTERVAL, function()
        local live = MB.transactions[txId]
        if not live or live.sessionEpoch ~= epoch or live.state ~= "SENT" or live.lifecyclePolling ~= true then return end
        if not MB.bridge.connected then return end
        if live.expiresAt and MB:Now() >= live.expiresAt then return end
        MB:BridgeSend("GET", "BOT_LIFECYCLE_STATE~" .. tostring(live.lifecycleGuid) .. "~" .. tostring(live.bridgeToken))
        MB:ScheduleBotLifecyclePoll(live)
    end)
end

function MB:BeginBotLifecycle(tx)
    if type(tx) ~= "table" then return false, "INVALID_TRANSACTION" end
    local action = lifecycleActionFromId(tx.actionId)
    local target = tx.targets and tx.targets[1]
    local guid = tonumber(tx.args and tx.args.guid) or tonumber(target and target.guid)
    if not action or not target or not guid or guid <= 0 then return false, "LIFECYCLE_TARGET_REQUIRED" end

    self.lifecycleByGuid = self.lifecycleByGuid or {}
    local existing = self.lifecycleByGuid[guid]
    if existing and existing ~= tx.id then return false, "LIFECYCLE_BUSY" end

    local token = self:NewToken(action == "CONNECT" and "bc" or "bd")
    tx.bridgeToken = token
    tx.lifecycleGuid = guid
    tx.lifecycleAction = action
    tx.transportRoute = "BRIDGE_NATIVE"
    tx.sentAt = self:Now()
    tx.expiresAt = tx.sentAt + LIFECYCLE_TIMEOUT
    tx.ackTimeoutSeconds = LIFECYCLE_TIMEOUT
    tx.lifecyclePolling = false
    self.lifecycleByGuid[guid] = tx.id
    self.bridge.actionTokens[token] = tx.id

    self:SetTransactionState(tx, "SENT")
    local requestType = action == "CONNECT" and "BOT_CONNECT" or "BOT_DISCONNECT"
    local ok, err = self:BridgeSend("RUN", requestType .. "~" .. tostring(guid) .. "~" .. token)
    if not ok then
        clearLifecycleReservation(self, tx)
        return false, err or "SEND_FAILED"
    end
    return true, token
end

function MB:HandleBotLifecyclePacket(result)
    if type(result) ~= "table" then return false end
    local token = self:Trim(result.token)
    local txId = self.bridge.actionTokens[token]
    local tx = txId and self.transactions[txId] or nil
    if not tx or tx.sessionEpoch ~= self.sessionEpoch then return true end
    if tx.actionId ~= "BOT.CONNECT" and tx.actionId ~= "BOT.DISCONNECT" then return false end

    local action = lifecycleActionFromId(tx.actionId)
    local guid = tonumber(result.guid)
    local status = self:Upper(result.status)
    if guid ~= tonumber(tx.lifecycleGuid) or self:Upper(result.action) ~= action then
        self.bridge.lastError = "BOT_LIFECYCLE_RESPONSE_MISMATCH"
        return true
    end
    if status ~= "OK" and status ~= "PENDING" and status ~= "ERR" then
        self.bridge.lastError = "BOT_LIFECYCLE_BAD_STATUS"
        return true
    end

    local lifecycleState
    if action == "CONNECT" then
        lifecycleState = status == "PENDING" and "CONNECTING" or (status == "OK" and "ONLINE" or "OFFLINE")
    else
        lifecycleState = status == "PENDING" and "DISCONNECTING" or (status == "OK" and "OFFLINE" or "ONLINE")
    end
    result.lifecycleState = lifecycleState
    result.final = status ~= "PENDING"
    result.proof = "BOT_LIFECYCLE"

    if status == "PENDING" then
        tx.result = self:Copy(result)
        tx.lifecycleState = lifecycleState
        self:ApplyLifecycleTransient(guid, result.name, lifecycleState, "BOT_LIFECYCLE_PENDING")
        self:Emit("MB_ACTION_VERIFICATION_UPDATED", tx.id, {
            action = action, status = "PENDING", proof = "BOT_LIFECYCLE", lifecycleState = lifecycleState,
            guid = guid, botName = result.name, reason = result.reason,
        }, self:TransactionSnapshot(tx))
        if tx.lifecyclePolling ~= true then
            tx.lifecyclePolling = true
            self:ScheduleBotLifecyclePoll(tx)
        end
        return true
    end

    return self:FinalizeBotLifecycle(tx, result, status == "OK")
end

function MB:HandleBotLifecycleStatePacket(result)
    if type(result) ~= "table" then return false end
    local token = self:Trim(result.token)
    local txId = self.bridge.actionTokens[token]
    local tx = txId and self.transactions[txId] or nil
    if not tx or tx.sessionEpoch ~= self.sessionEpoch then return true end
    local action = lifecycleActionFromId(tx.actionId)
    if not action then return false end

    local guid = tonumber(result.guid)
    local lifecycleState = normalizeLifecycleState(self, result.lifecycleState)
    if guid ~= tonumber(tx.lifecycleGuid) then self.bridge.lastError = "BOT_LIFECYCLE_STATE_MISMATCH"; return true end
    if lifecycleState ~= "ONLINE" and lifecycleState ~= "OFFLINE" and lifecycleState ~= "CONNECTING" then
        self.bridge.lastError = "BOT_LIFECYCLE_STATE_BAD_PAYLOAD"; return true
    end

    result.action = action
    result.status = lifecycleState == "CONNECTING" and "PENDING" or "OK"
    result.final = lifecycleState ~= "CONNECTING"
    result.proof = "BOT_LIFECYCLE_STATE"

    if lifecycleState == "CONNECTING" then
        tx.result = self:Copy(result)
        tx.lifecycleState = lifecycleState
        self:ApplyLifecycleTransient(guid, result.name, lifecycleState, "BOT_LIFECYCLE_STATE")
        self:Emit("MB_ACTION_VERIFICATION_UPDATED", tx.id, {
            action = action, status = "PENDING", proof = result.proof, lifecycleState = lifecycleState,
            guid = guid, botName = result.name, reason = result.reason,
        }, self:TransactionSnapshot(tx))
        return true
    end

    local success = (action == "CONNECT" and lifecycleState == "ONLINE") or (action == "DISCONNECT" and lifecycleState == "OFFLINE")
    if not success then result.status = "ERR" end
    return self:FinalizeBotLifecycle(tx, result, success)
end

function MB:HandleBotLifecycleProtocolError(requestType, token, reason)
    requestType = self:Upper(requestType)
    if requestType ~= "BOT_CONNECT" and requestType ~= "BOT_DISCONNECT" and requestType ~= "BOT_LIFECYCLE_STATE" then return false end
    token = self:Trim(token)
    local txId = self.bridge.actionTokens[token]
    local tx = txId and self.transactions[txId] or nil
    if not tx then return true end
    if requestType == "BOT_LIFECYCLE_STATE" and self:Upper(reason) == "RATE_LIMIT" then return true end
    local action = lifecycleActionFromId(tx.actionId)
    if not action then return false end
    local result = {
        token = token, guid = tx.lifecycleGuid, name = tx.targets and tx.targets[1] and tx.targets[1].name or "",
        action = action, status = "ERR", reason = self:Trim(reason) ~= "" and self:Trim(reason) or "PROTOCOL_ERROR",
        lifecycleState = actionFallbackState(action), final = true, proof = "BRIDGE_ERR",
    }
    return self:FinalizeBotLifecycle(tx, result, false)
end

function MB:OnBotLifecycleTimeout(tx)
    if type(tx) ~= "table" or (tx.actionId ~= "BOT.CONNECT" and tx.actionId ~= "BOT.DISCONNECT") then return false end
    clearLifecycleReservation(self, tx)
    tx.lifecyclePolling = false
    self:RefreshLifecycleAuthorities(tx.targets and tx.targets[1] and tx.targets[1].name)
    return true
end

function MB:AbortLifecycleWorkflows()
    self.lifecycleByGuid = {}
end
