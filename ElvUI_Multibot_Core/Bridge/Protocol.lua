local _, MB = ...

local STATE_MAX_ACTIVE = 32
local STATE_MAX_BOTS = 128
local STATE_MAX_STRATEGIES_PER_SCOPE = 256
local STATE_MAX_STRATEGY_LENGTH = 192
local STATE_MAX_TOTAL_BYTES = 32768

local function parseIntegerRange(value, minimum, maximum)
    local n = tonumber(value)
    if not n or n ~= math.floor(n) or n < minimum or n > maximum then return nil end
    return n
end

local function bridgeReady(self)
    return self.db and self.db.enabled and self.db.bridge.enabled and (self.bridge.connected or self.bridge.bootstrapPending)
end

local function newFrame(self, kind, token, data)
    data = data or {}
    data.kind = kind
    data.token = token
    data.startedAt = self:Now()
    data.sessionEpoch = self.sessionEpoch
    self.bridge.frames[token] = data
    return data
end

local function getFrame(self, token, kind)
    local frame = self.bridge.frames[self:Trim(token)]
    if not frame then return nil end
    if kind and frame.kind ~= kind then return nil end
    if frame.sessionEpoch ~= self.sessionEpoch then return nil end
    return frame
end

local function finishFrame(self, token)
    local frame = self.bridge.frames[token]
    self.bridge.frames[token] = nil
    return frame
end

local function sendTokenRead(self, kind, payload, frameData)
    if not bridgeReady(self) then return false, "BRIDGE_NOT_CONNECTED" end
    local token = self:NewToken(string.lower(kind))
    local frame = newFrame(self, kind, token, frameData)
    local ok, err = self:BridgeSend("GET", payload(token))
    if not ok then self.bridge.frames[token] = nil; return false, err end
    return true, token, frame
end

function MB:BridgeRequestRoster()
    if not bridgeReady(self) then return false, "BRIDGE_NOT_CONNECTED" end
    return self:BridgeSend("GET", "ROSTER")
end


function MB:BridgeRequestAltRoster()
    if not bridgeReady(self) then return false, "BRIDGE_NOT_CONNECTED" end
    if not self:BridgeHasCapability("ALT_ROSTER_V1") then return false, "CAPABILITY_UNAVAILABLE" end
    return self:BridgeSend("GET", "ALT_ROSTER")
end

function MB:BridgeRequestBotTargetResolve(name)
    name = self:NormalizeName(name)
    if not name then return false, "BOT_REQUIRED" end
    if not self:BridgeHasCapability("BOT_TARGET_RESOLVE_V1") then return false, "CAPABILITY_UNAVAILABLE" end
    return sendTokenRead(self, "BOT_TARGET_RESOLVE", function(token)
        return "BOT_TARGET_RESOLVE~" .. self:EncodeField(name) .. "~" .. token
    end, { botName = name, botKey = self:BotKey(name), requestedNameKey = self:Lower(name) })
end

function MB:BridgeRequestDetails()
    if not bridgeReady(self) then return false, "BRIDGE_NOT_CONNECTED" end
    return self:BridgeSend("GET", "DETAILS")
end

function MB:BridgeRequestDetail(name)
    name = self:NormalizeName(name)
    if not name then return false, "BOT_REQUIRED" end
    if not bridgeReady(self) then return false, "BRIDGE_NOT_CONNECTED" end
    return self:BridgeSend("GET", "DETAIL~" .. name)
end

function MB:BridgeRequestState(name)
    name = self:NormalizeName(name)
    if not name then return false, "BOT_REQUIRED" end
    if not bridgeReady(self) then return false, "BRIDGE_NOT_CONNECTED" end
    if not self:BridgeHasCapability("STATE_FRAMING_V1") then return self:BridgeSend("GET", "STATE~" .. name) end

    self.bridge.stateOrder = (self.bridge.stateOrder or 0) + 1
    local order = self.bridge.stateOrder
    local token = self:NewToken("state")
    local botKey = self:BotKey(name)
    newFrame(self, "STATE_REQUEST", token, { global = false, botName = name, botKey = botKey, order = order, active = {} })
    self.bridge.stateLatestOrderByBot[botKey] = math.max(order, tonumber(self.bridge.stateLatestOrderByBot[botKey]) or 0)
    local ok, err = self:BridgeSend("GET", "STATE~" .. self:EncodeField(name) .. "~" .. token)
    if not ok then self.bridge.frames[token] = nil; return false, err end
    return true, token
end

function MB:BridgeRequestStates()
    if not bridgeReady(self) then return false, "BRIDGE_NOT_CONNECTED" end
    if not self:BridgeHasCapability("STATE_FRAMING_V1") then return self:BridgeSend("GET", "STATES") end

    self.bridge.stateOrder = (self.bridge.stateOrder or 0) + 1
    local token = self:NewToken("states")
    newFrame(self, "STATE_REQUEST", token, {
        global = true, order = self.bridge.stateOrder, active = {}, begun = false,
        expectedBots = 0, completedBots = 0, completedBotKeys = {},
    })
    self.bridge.stateGlobalLatestToken = token
    local ok, err = self:BridgeSend("GET", "STATES~" .. token)
    if not ok then self.bridge.frames[token] = nil; return false, err end
    return true, token
end

function MB:BridgeRequestStats(name)
    name = self:NormalizeName(name)
    if not bridgeReady(self) then return false, "BRIDGE_NOT_CONNECTED" end
    return self:BridgeSend("GET", name and ("STATS~" .. name) or "STATS")
end

function MB:BridgeRequestPvpStats(name)
    name = self:NormalizeName(name)
    if not bridgeReady(self) then return false, "BRIDGE_NOT_CONNECTED" end
    return self:BridgeSend("GET", name and ("PVP_STATS~" .. name) or "PVP_STATS")
end

function MB:BridgeRequestWeaponEnchant(name)
    name = self:NormalizeName(name)
    if not name then return false, "BOT_REQUIRED" end
    return sendTokenRead(self, "WEAPON_ENCHANT", function(token)
        return "WEAPON_ENCHANT~" .. self:EncodeField(name) .. "~" .. token
    end, { botName = name, botKey = self:BotKey(name) })
end

function MB:BridgeRequestTalentSpecs(name)
    name = self:NormalizeName(name)
    if not name then return false, "BOT_REQUIRED" end
    return sendTokenRead(self, "TALENT_SPEC_LIST", function(token)
        return "TALENT_SPEC_LIST~" .. name .. "~" .. token
    end, { botName = name, botKey = self:BotKey(name), items = {}, current = nil, begun = false })
end

function MB:BridgeRequestGlyphs(name)
    name = self:NormalizeName(name)
    if not name then return false, "BOT_REQUIRED" end
    return sendTokenRead(self, "GLYPHS", function(token)
        return "GLYPHS~" .. name .. "~" .. token
    end, { botName = name, botKey = self:BotKey(name), items = {}, begun = false })
end

function MB:BridgeRequestInventory(name)
    name = self:NormalizeName(name)
    if not name then return false, "BOT_REQUIRED" end
    return sendTokenRead(self, "INVENTORY", function(token)
        return "INVENTORY~" .. name .. "~" .. token
    end, { botName = name, botKey = self:BotKey(name), items = {}, summary = {}, begun = false })
end

function MB:BridgeRequestInventoryExact(name)
    name = self:NormalizeName(name)
    if not name then return false, "BOT_REQUIRED" end
    if not self:BridgeHasCapability("INVENTORY_EXACT_V1") then return false, "CAPABILITY_UNAVAILABLE" end
    return sendTokenRead(self, "INVENTORY_EXACT", function(token)
        return "INVENTORY_EXACT~" .. name .. "~" .. token
    end, {
        botName = name, botKey = self:BotKey(name), bags = {}, items = {}, itemsByPosition = {},
        begun = false, integrityError = nil,
    })
end

function MB:BridgeRequestBuyback(name)
    name = self:NormalizeName(name)
    if not name then return false, "BOT_REQUIRED" end
    if not self:BridgeHasCapability("INVENTORY_EXACT_V1") or not self:BridgeHasCapability("VENDOR_BUYBACK_V1") then return false, "CAPABILITY_UNAVAILABLE" end
    return sendTokenRead(self, "BUYBACK", function(token)
        return "BUYBACK~" .. name .. "~" .. token
    end, {
        botName = name, botKey = self:BotKey(name), items = {}, seenSlots = {}, begun = false,
        expectedCount = nil, integrityError = nil,
    })
end

function MB:BridgeRequestBank(name)
    name = self:NormalizeName(name)
    if not name then return false, "BOT_REQUIRED" end
    return sendTokenRead(self, "BANK", function(token)
        return "BANK~" .. name .. "~" .. token
    end, { botName = name, botKey = self:BotKey(name), items = {}, begun = false })
end

function MB:BridgeRequestGuildBank(name)
    name = self:NormalizeName(name)
    if not name then return false, "BOT_REQUIRED" end
    return sendTokenRead(self, "GBANK", function(token)
        return "GBANK~" .. name .. "~" .. token
    end, { botName = name, botKey = self:BotKey(name), items = {}, begun = false })
end

function MB:BridgeRequestSpellbook(name)
    name = self:NormalizeName(name)
    if not name then return false, "BOT_REQUIRED" end
    return sendTokenRead(self, "SPELLBOOK", function(token)
        return "SPELLBOOK~" .. name .. "~" .. token
    end, { botName = name, botKey = self:BotKey(name), spellIds = {}, begun = false })
end

function MB:BridgeRequestSkills(name)
    name = self:NormalizeName(name)
    if not name then return false, "BOT_REQUIRED" end
    return sendTokenRead(self, "BOT_SKILLS", function(token)
        return "BOT_SKILLS~" .. name .. "~" .. token
    end, { botName = name, botKey = self:BotKey(name), items = {}, begun = false })
end

function MB:BridgeRequestReputations(name)
    name = self:NormalizeName(name)
    if not name then return false, "BOT_REQUIRED" end
    return sendTokenRead(self, "BOT_REPUTATIONS", function(token)
        return "BOT_REPUTATIONS~" .. name .. "~" .. token
    end, { botName = name, botKey = self:BotKey(name), items = {}, begun = false })
end

function MB:BridgeRequestEmblems(name)
    name = self:NormalizeName(name)
    if not name then return false, "BOT_REQUIRED" end
    return sendTokenRead(self, "BOT_EMBLEMS", function(token)
        return "BOT_EMBLEMS~" .. name .. "~" .. token
    end, { botName = name, botKey = self:BotKey(name), items = {}, money = nil, begun = false })
end

function MB:BridgeRequestProfessionRecipes(name, skillId)
    name = self:NormalizeName(name)
    skillId = tonumber(skillId) or 0
    if not name or skillId <= 0 then return false, "BOT_AND_SKILL_REQUIRED" end
    return sendTokenRead(self, "PROFESSION_RECIPES", function(token)
        return "PROFESSION_RECIPES~" .. name .. "~" .. tostring(skillId) .. "~" .. token
    end, { botName = name, botKey = self:BotKey(name), skillId = skillId, recipes = {}, begun = false })
end

function MB:BridgeRequestOutfits(name)
    name = self:NormalizeName(name)
    if not name then return false, "BOT_REQUIRED" end
    return sendTokenRead(self, "OUTFITS", function(token)
        return "OUTFITS~" .. name .. "~" .. token
    end, { botName = name, botKey = self:BotKey(name), lines = {}, begun = false })
end

function MB:BridgeRequestTrainer(name)
    name = self:NormalizeName(name)
    if not name then return false, "BOT_REQUIRED" end
    return sendTokenRead(self, "TRAINER", function(token)
        return "TRAINER~" .. name .. "~" .. token
    end, { botName = name, botKey = self:BotKey(name), spells = {}, begun = false })
end

function MB:BridgeRequestQuests(name, mode)
    name = self:NormalizeName(name)
    mode = self:Upper(mode ~= nil and mode or "ALL")
    if mode ~= "INCOMPLETED" and mode ~= "COMPLETED" and mode ~= "ALL" then mode = "ALL" end
    if not name then return false, "BOT_REQUIRED" end
    return sendTokenRead(self, "QUESTS", function(token)
        return "QUESTS~" .. mode .. "~" .. name .. "~" .. token
    end, { botName = name, botKey = self:BotKey(name), mode = mode, bots = {} })
end

function MB:BridgeRequestGameObjects(name)
    name = self:NormalizeName(name)
    if not name then return false, "BOT_REQUIRED" end
    return sendTokenRead(self, "GAMEOBJECTS", function(token)
        return "GAMEOBJECTS~" .. name .. "~" .. token
    end, { botName = name, botKey = self:BotKey(name), bots = {} })
end

function MB:BridgeRequestFormations()
    return sendTokenRead(self, "FORMATIONS", function(token)
        return "FORMATIONS~GROUP~~" .. token
    end, { items = {}, begun = false, expected = 0 })
end

function MB:DispatchDomainRead(request)
    local provider = request.descriptor.provider
    local info = request.targetInfo or {}
    local ok, tokenOrError
    if provider == "ROSTER" then ok, tokenOrError = self:BridgeRequestRoster()
    elseif provider == "ALT_ROSTER" then ok, tokenOrError = self:BridgeRequestAltRoster()
    elseif provider == "BOT_TARGET_RESOLVE" then ok, tokenOrError = self:BridgeRequestBotTargetResolve(info.botName)
    elseif provider == "STATE" then ok, tokenOrError = self:BridgeRequestState(info.botName)
    elseif provider == "DETAIL" then ok, tokenOrError = self:BridgeRequestDetail(info.botName)
    elseif provider == "PROFESSIONS" then ok, tokenOrError = self:BridgeRequestDetails()
    elseif provider == "STATS" then ok, tokenOrError = self:BridgeRequestStats(info.botName)
    elseif provider == "PVP_STATS" then ok, tokenOrError = self:BridgeRequestPvpStats(info.botName)
    elseif provider == "WEAPON_ENCHANT" then ok, tokenOrError = self:BridgeRequestWeaponEnchant(info.botName)
    elseif provider == "TALENT_SPEC_LIST" then ok, tokenOrError = self:BridgeRequestTalentSpecs(info.botName)
    elseif provider == "GLYPHS" then ok, tokenOrError = self:BridgeRequestGlyphs(info.botName)
    elseif provider == "INVENTORY" then ok, tokenOrError = self:BridgeRequestInventory(info.botName)
    elseif provider == "INVENTORY_EXACT" then ok, tokenOrError = self:BridgeRequestInventoryExact(info.botName)
    elseif provider == "BUYBACK" then ok, tokenOrError = self:BridgeRequestBuyback(info.botName)
    elseif provider == "BANK" then ok, tokenOrError = self:BridgeRequestBank(info.botName)
    elseif provider == "GBANK" then ok, tokenOrError = self:BridgeRequestGuildBank(info.botName)
    elseif provider == "SPELLBOOK" then ok, tokenOrError = self:BridgeRequestSpellbook(info.botName)
    elseif provider == "BOT_SKILLS" then ok, tokenOrError = self:BridgeRequestSkills(info.botName)
    elseif provider == "BOT_REPUTATIONS" then ok, tokenOrError = self:BridgeRequestReputations(info.botName)
    elseif provider == "BOT_EMBLEMS" then ok, tokenOrError = self:BridgeRequestEmblems(info.botName)
    elseif provider == "PROFESSION_RECIPES" then ok, tokenOrError = self:BridgeRequestProfessionRecipes(info.botName, info.skillId or info.variant)
    elseif provider == "OUTFITS" then ok, tokenOrError = self:BridgeRequestOutfits(info.botName)
    elseif provider == "TRAINER" then ok, tokenOrError = self:BridgeRequestTrainer(info.botName)
    elseif provider == "QUESTS" then ok, tokenOrError = self:BridgeRequestQuests(info.botName, "ALL")
    elseif provider == "QUEST_METADATA_CHAT" then ok, tokenOrError = self:BeginQuestMetadataRead(request)
    elseif provider == "GAMEOBJECTS" then ok, tokenOrError = self:BridgeRequestGameObjects(info.botName)
    elseif provider == "FORMATIONS" then ok, tokenOrError = self:BridgeRequestFormations()
    else return false, "NO_PROVIDER" end
    if not ok then return false, tokenOrError or "SEND_FAILED" end
    if type(tokenOrError) == "string" then return true, tokenOrError end
    return true, nil
end

local function commitBotState(self, name, combatStrategies, normalStrategies, token, source)
    local botKey = self:BotKey(name)
    if not botKey then return false end
    local snapshot = {
        name = self:NormalizeName(name),
        combatStrategies = combatStrategies or {},
        normalStrategies = normalStrategies or {},
        combat = table.concat(combatStrategies or {}, ", "),
        normal = table.concat(normalStrategies or {}, ", "),
    }
    self:CommitData("BOT.STATE", botKey, snapshot, { source = source or "BRIDGE", token = token })
    return true
end

local function parseLegacyStrategies(value)
    local out = {}
    for token in string.gmatch(tostring(value or ""), "([^,]+)") do
        token = MB:Trim(token)
        if token ~= "" then out[#out + 1] = token end
    end
    return out
end

local function parseRoster(self, payload)
    local roster = {}
    for entry in string.gmatch(tostring(payload or ""), "([^;]+)") do
        local f = self:Split(entry, ",", true)
        if self:Trim(f[1]) ~= "" then
            roster[#roster + 1] = {
                name = self:Trim(f[1]), classId = tonumber(f[2]) or 0, level = tonumber(f[3]) or 0,
                mapId = tonumber(f[4]) or 0, alive = tostring(f[5]) == "1",
                hpPct = tonumber(f[6]) or 0, mpPct = tonumber(f[7]) or 0,
            }
        end
    end
    return roster
end

local function parseDetail(self, payload)
    local f = self:Split(payload, "~", true)
    local name = self:NormalizeName(self:DecodeField(f[1]))
    if not name then return nil end
    return {
        name = name, race = self:DecodeField(f[2]), gender = self:DecodeField(f[3]), className = self:DecodeField(f[4]),
        level = tonumber(f[5]) or 0, talent1 = tonumber(f[6]) or 0, talent2 = tonumber(f[7]) or 0,
        talent3 = tonumber(f[8]) or 0, score = tonumber(f[9]) or 0,
    }
end

local function parseProfession(self, payload)
    local name, raw = self:SplitOnce(payload, "~")
    name = self:NormalizeName(self:DecodeField(name))
    if not name then return nil end
    local professions = {}
    for token in string.gmatch(raw or "", "([^;]+)") do
        token = self:Trim(self:DecodeField(token))
        local profession, value = self:SplitOnce(token, ":")
        profession = self:Lower(profession)
        if profession ~= "" then professions[profession] = self:Trim(value) ~= "" and self:Trim(value) or true end
    end
    return name, professions
end

local function parseStats(self, payload)
    local f = self:Split(payload, "~", true)
    local name = self:NormalizeName(self:DecodeField(f[1]))
    if not name then return nil end
    return {
        name = name, level = tonumber(f[2]) or 0, gold = tonumber(f[3]) or 0, silver = tonumber(f[4]) or 0,
        copper = tonumber(f[5]) or 0, bagUsed = tonumber(f[6]) or 0, bagTotal = tonumber(f[7]) or 0,
        durabilityPct = tonumber(f[8]) or 0, xpPct = tonumber(f[9]) or 0, manaPct = tonumber(f[10]) or 0,
    }
end

local function parsePvpStats(self, payload)
    local f = self:Split(payload, "~", true)
    local name = self:NormalizeName(self:DecodeField(f[1]))
    if not name then return nil end
    return {
        name = name, arenaPoints = tonumber(f[2]) or 0, honorPoints = tonumber(f[3]) or 0,
        teams = {
            ["2v2"] = { team = self:DecodeField(f[4]), rating = tonumber(f[5]) or 0 },
            ["3v3"] = { team = self:DecodeField(f[6]), rating = tonumber(f[7]) or 0 },
            ["5v5"] = { team = self:DecodeField(f[8]), rating = tonumber(f[9]) or 0 },
        },
    }
end

local function frameForBot(self, token, kind, encodedName)
    local frame = getFrame(self, token, kind)
    if not frame then return nil end
    local name = self:NormalizeName(self:DecodeField(encodedName))
    if not name or self:BotKey(name) ~= frame.botKey then return nil end
    return frame, name
end

local function parseRecipeMaterials(self, raw)
    local items = {}
    for token in string.gmatch(tostring(raw or ""), "([^;]+)") do
        local f = self:Split(token, ":", true)
        items[#items + 1] = { itemId = tonumber(f[1]) or 0, required = tonumber(f[2]) or 0, available = tonumber(f[3]) or 0 }
    end
    return items
end

local function resultIsSuccess(result)
    local r = string.upper(tostring(result or ""))
    return r == "OK" or r == "SUCCESS" or r == "1" or r == "DONE" or r == "TRUE"
end

function MB:ProtocolHandle(opcode, payload, distribution, sender)
    if opcode == "HELLO_ACK" then
        local protocol, server = self:SplitOnce(payload, "~")
        local wasReady = self.bridge.handshakeReady == true
        self.bridge.protocol = self:Trim(protocol)
        self.bridge.server = self:DecodeField(server)
        self.bridge.handshakeReady = self.bridge.protocol ~= ""
        self.bridge.bootstrapPending = false
        self.bridge.lastError = nil
        self:SetBridgeConnected(true)
        if self.bridge.handshakeReady and not wasReady then
            self:Emit("MB_BRIDGE_READY", self.sessionEpoch, self.bridge.server, self.bridge.protocol)
        end
        self:After(0.05, function() if MB.bridge.connected then MB:BridgeBootstrap("HELLO_ACK") end end)
        return true
    elseif opcode == "PONG" then
        self.bridge.lastPongAt = self:Now()
        self:SetBridgeConnected(true)
        return true
    elseif opcode == "CAPS_BEGIN" then
        -- Current bridge builds frame capability negotiation explicitly.  Treat one
        -- BEGIN..END sequence as a complete authoritative snapshot and keep the
        -- capability gate closed until END arrives, so actions cannot observe a
        -- partially accumulated set.
        self.bridge.capabilities = {}
        self.bridge.capabilityBatchActive = true
        self.bridge.capabilitiesResolved = false
        return true
    elseif opcode == "CAPS" then
        -- Legacy/non-batched bridges may send a single CAPS message.  Batched bridges
        -- send several CAPS payloads between CAPS_BEGIN/CAPS_END.
        if not self.bridge.capabilityBatchActive then
            self.bridge.capabilities = {}
        end
        local capabilities = self:Copy(self.bridge.capabilities or {})
        for cap in string.gmatch(tostring(payload or ""), "([^,]+)") do
            cap = self:Trim(cap)
            if cap ~= "" then capabilities[cap] = true end
        end
        self.bridge.capabilities = capabilities
        if not self.bridge.capabilityBatchActive then
            self.bridge.capabilitiesResolved = true
            self:Emit("MB_BRIDGE_CAPABILITIES_CHANGED", self:Copy(capabilities))
        end
        return true
    elseif opcode == "CAPS_END" then
        if self.bridge.capabilityBatchActive then
            self.bridge.capabilityBatchActive = false
            self.bridge.capabilitiesResolved = true
            self:Emit("MB_BRIDGE_CAPABILITIES_CHANGED", self:Copy(self.bridge.capabilities or {}))
            if self:BridgeHasCapability("ALT_ROSTER_V1") then
                self:After(0.05, function()
                    if MB.bridge.connected and MB:BridgeHasCapability("ALT_ROSTER_V1") then MB:RefreshDomain("ALT.ROSTER") end
                end)
            end
        end
        return true
    elseif opcode == "ALT_ROSTER_BEGIN" then
        local f = self:Split(payload, "~", true)
        local expected = #f == 2 and parseIntegerRange(f[1], 0, 128) or nil
        local truncated = #f == 2 and parseIntegerRange(f[2], 0, 1) or nil
        if expected == nil or truncated == nil then
            self.bridge.altRosterBatch = nil
            local request = self.pendingReads[self:ReadKey("ALT.ROSTER", "GLOBAL")]
            if request then self:FailRead(request, "ALT_ROSTER_BEGIN_BAD_PAYLOAD") end
            self.bridge.lastError = "ALT_ROSTER_BEGIN_BAD_PAYLOAD"
            return true
        end
        self.bridge.altRosterBatch = { expectedCount = expected, truncated = truncated, items = {}, seenGuids = {}, seenNames = {} }
        return true
    elseif opcode == "ALT_ROSTER_ENTRY" then
        local batch = self.bridge.altRosterBatch
        if type(batch) ~= "table" then self.bridge.lastError = "ALT_ROSTER_ENTRY_WITHOUT_BEGIN"; return true end
        local f = self:Split(payload, "~", true)
        local guid = #f == 5 and parseIntegerRange(f[1], 1, 4294967295) or nil
        local name = #f == 5 and self:NormalizeName(self:DecodeField(f[2])) or nil
        local classId = #f == 5 and parseIntegerRange(f[3], 1, 11) or nil
        local level = #f == 5 and parseIntegerRange(f[4], 1, 255) or nil
        local state = #f == 5 and self:Upper(f[5]) or ""
        local key = name and self:Lower(name) or nil
        if not guid or not name or not classId or not level or (state ~= "ONLINE" and state ~= "OFFLINE")
            or batch.seenGuids[guid] or batch.seenNames[key] or #batch.items >= batch.expectedCount then
            self.bridge.altRosterBatch = nil
            local request = self.pendingReads[self:ReadKey("ALT.ROSTER", "GLOBAL")]
            if request then self:FailRead(request, "ALT_ROSTER_ENTRY_INVALID") end
            self.bridge.lastError = "ALT_ROSTER_ENTRY_INVALID"
            return true
        end
        batch.seenGuids[guid] = true; batch.seenNames[key] = true
        batch.items[#batch.items + 1] = { guid = guid, name = name, classId = classId, level = level, state = state }
        return true
    elseif opcode == "ALT_ROSTER_END" then
        local batch = self.bridge.altRosterBatch
        if type(batch) ~= "table" then self.bridge.lastError = "ALT_ROSTER_END_WITHOUT_BEGIN"; return true end
        local f = self:Split(payload, "~", true)
        local count = #f == 2 and parseIntegerRange(f[1], 0, 128) or nil
        local truncated = #f == 2 and parseIntegerRange(f[2], 0, 1) or nil
        if count == nil or truncated == nil or count ~= batch.expectedCount or count ~= #batch.items or truncated ~= batch.truncated then
            self.bridge.altRosterBatch = nil
            local request = self.pendingReads[self:ReadKey("ALT.ROSTER", "GLOBAL")]
            if request then self:FailRead(request, "ALT_ROSTER_END_MISMATCH") end
            self.bridge.lastError = "ALT_ROSTER_END_MISMATCH"
            return true
        end
        local byGuid, byName = {}, {}
        table.sort(batch.items, function(a, b) return self:Lower(a.name) < self:Lower(b.name) end)
        for _, item in ipairs(batch.items) do byGuid[item.guid] = item; byName[self:Lower(item.name)] = item end
        local snapshot = { schemaVersion = 1, items = batch.items, count = #batch.items, truncated = truncated == 1, byGuid = byGuid, byName = byName }
        self.bridge.altRosterBatch = nil
        self:CommitData("ALT.ROSTER", "GLOBAL", snapshot, { source = "BRIDGE" })
        if self.SyncAltRoster then self:SyncAltRoster(snapshot) end
        if self.SyncManagedAltRoster then self:SyncManagedAltRoster(snapshot) end
        return true
    elseif opcode == "BOT_TARGET_RESOLVE" then
        local f = self:Split(payload, "~", true)
        local token = self:Trim(f[1])
        local frame = getFrame(self, token, "BOT_TARGET_RESOLVE")
        if not frame then return true end
        if #f ~= 6 then
            local request = self:FindPendingReadByToken(token); if request then self:FailRead(request, "BOT_TARGET_RESOLVE_BAD_FIELD_COUNT") end
            finishFrame(self, token); return true
        end
        local status, reason = self:Upper(f[2]), self:DecodeField(f[3])
        local name = self:NormalizeName(self:DecodeField(f[4]))
        local guid = parseIntegerRange(f[5], 0, 4294967295)
        local state = self:Upper(f[6])
        local okValid = status == "OK" and reason ~= "" and name and guid and guid > 0 and self:Lower(name) == frame.requestedNameKey
            and (state == "ONLINE" or state == "CONNECTING" or state == "OFFLINE")
        local errValid = status == "ERR" and reason ~= "" and (not name) and guid == 0 and state == "UNKNOWN"
        if not okValid and not errValid then
            local request = self:FindPendingReadByToken(token); if request then self:FailRead(request, "BOT_TARGET_RESOLVE_BAD_RESPONSE") end
            finishFrame(self, token); return true
        end
        local value = { schemaVersion = 1, status = status, reason = reason, name = name or "", guid = guid or 0, lifecycleState = state, final = true }
        self:CommitData("BOT.LIFECYCLE_TARGET", frame.botKey, value, { source = "BRIDGE", token = token })
        if okValid then
            self:UpsertBot(name, {
                guid = guid, lifecycleState = state, altOnline = state == "ONLINE", managedKnown = true,
                lifecycleSessionEpoch = self.sessionEpoch, lifecycleObservedAt = self:Now(), lifecycleStateSource = "BOT_TARGET_RESOLVE",
            }, "BOT.LIFECYCLE_TARGET")
            if self.RecordManagedResolution then self:RecordManagedResolution(value) end
        end
        finishFrame(self, token)
        return true
    elseif opcode == "BOT_LIFECYCLE" then
        local f = self:Split(payload, "~", true)
        if #f ~= 6 then self.bridge.lastError = "BOT_LIFECYCLE_BAD_FIELD_COUNT"; return true end
        local result = {
            token = self:Trim(f[1]), guid = parseIntegerRange(f[2], 1, 4294967295), name = self:NormalizeName(self:DecodeField(f[3])) or "",
            action = self:Upper(f[4]), status = self:Upper(f[5]), reason = self:DecodeField(f[6]),
        }
        if not result.guid or (result.action ~= "CONNECT" and result.action ~= "DISCONNECT")
            or (result.status ~= "OK" and result.status ~= "PENDING" and result.status ~= "ERR") then
            self.bridge.lastError = "BOT_LIFECYCLE_BAD_PAYLOAD"; return true
        end
        if self.HandleBotLifecyclePacket then return self:HandleBotLifecyclePacket(result) end
        return true
    elseif opcode == "BOT_LIFECYCLE_STATE" then
        local f = self:Split(payload, "~", true)
        if #f ~= 5 then self.bridge.lastError = "BOT_LIFECYCLE_STATE_BAD_FIELD_COUNT"; return true end
        local result = {
            token = self:Trim(f[1]), guid = parseIntegerRange(f[2], 1, 4294967295), name = self:NormalizeName(self:DecodeField(f[3])) or "",
            lifecycleState = self:Upper(f[4]), reason = self:DecodeField(f[5]),
        }
        if not result.guid or (result.lifecycleState ~= "ONLINE" and result.lifecycleState ~= "CONNECTING" and result.lifecycleState ~= "OFFLINE") then
            self.bridge.lastError = "BOT_LIFECYCLE_STATE_BAD_PAYLOAD"; return true
        end
        if self.HandleBotLifecycleStatePacket then return self:HandleBotLifecycleStatePacket(result) end
        return true
    elseif opcode == "ROSTER" then
        local roster = parseRoster(self, payload)
        self:CommitData("BRIDGE.ROSTER", "GLOBAL", roster, { source = "BRIDGE" })
        self:SyncRoster(roster)
        if not self.botRegistryReady or self.botRegistryReadyEpoch ~= self.sessionEpoch then
            self.botRegistryReady = true
            self.botRegistryReadyEpoch = self.sessionEpoch
            self:Emit("MB_BOT_REGISTRY_READY", self.sessionEpoch, self:Copy(roster))
        end
        return true
    elseif opcode == "DETAIL" then
        local detail = parseDetail(self, payload)
        if detail then
            local key = self:BotKey(detail.name)
            self:CommitData("BOT.DETAIL", key, detail, { source = "BRIDGE" })
            self:MergeBotDetail(detail)
        end
        return true
    elseif opcode == "DETAILS" then
        for entry in string.gmatch(tostring(payload or ""), "([^;]+)") do
            local detail = parseDetail(self, entry)
            if detail then
                local key = self:BotKey(detail.name)
                self:CommitData("BOT.DETAIL", key, detail, { source = "BRIDGE" })
                self:MergeBotDetail(detail)
            end
        end
        return true
    elseif opcode == "PROFESSION" then
        local name, professions = parseProfession(self, payload)
        if name then
            local key = self:BotKey(name)
            self:CommitData("BOT.PROFESSIONS", key, { name = name, professions = professions }, { source = "BRIDGE" })
            self:MergeBotProfessions(name, professions)
        end
        return true
    elseif opcode == "PROFESSIONS" then
        for entry in string.gmatch(tostring(payload or ""), "([^|]+)") do
            local name, professions = parseProfession(self, entry)
            if name then
                local key = self:BotKey(name)
                self:CommitData("BOT.PROFESSIONS", key, { name = name, professions = professions }, { source = "BRIDGE" })
                self:MergeBotProfessions(name, professions)
            end
        end
        return true
    elseif opcode == "STATS" then
        local stats = parseStats(self, payload)
        if stats then self:CommitData("BOT.STATS", self:BotKey(stats.name), stats, { source = "BRIDGE" }) end
        return true
    elseif opcode == "PVP_STATS" then
        local stats = parsePvpStats(self, payload)
        if stats then self:CommitData("BOT.PVP_STATS", self:BotKey(stats.name), stats, { source = "BRIDGE" }) end
        return true
    elseif opcode == "STATE" then
        local name, rest = self:SplitOnce(payload, "~")
        local combat, normal = self:SplitOnce(rest, "~")
        name = self:NormalizeName(name)
        if name then commitBotState(self, name, parseLegacyStrategies(combat), parseLegacyStrategies(normal), nil, "BRIDGE_LEGACY") end
        return true
    elseif opcode == "STATES" then
        for entry in string.gmatch(tostring(payload or ""), "([^;]+)") do
            local name, rest = self:SplitOnce(entry, "~")
            local combat, normal = self:SplitOnce(rest, "~")
            name = self:NormalizeName(name)
            if name then commitBotState(self, name, parseLegacyStrategies(combat), parseLegacyStrategies(normal), nil, "BRIDGE_LEGACY") end
        end
        return true
    end

    if opcode == "STATE_BEGIN" then
        local f = self:Split(payload, "~", true)
        if #f ~= 4 then return true end
        local token, name = self:Trim(f[1]), self:NormalizeName(self:DecodeField(f[2]))
        local combatExpected, normalExpected = tonumber(f[3]), tonumber(f[4])
        local frame = getFrame(self, token, "STATE_REQUEST")
        if not frame or not name or not combatExpected or not normalExpected then return true end
        if combatExpected < 0 or normalExpected < 0 or combatExpected > STATE_MAX_STRATEGIES_PER_SCOPE or normalExpected > STATE_MAX_STRATEGIES_PER_SCOPE then return true end
        local botKey = self:BotKey(name)
        if frame.global and not frame.begun then return true end
        if not frame.global and botKey ~= frame.botKey then return true end
        if self:TableCount(frame.active) >= STATE_MAX_ACTIVE or frame.active[botKey] then return true end
        frame.active[botKey] = {
            name = name, botKey = botKey, combatExpected = combatExpected, normalExpected = normalExpected,
            combat = {}, normal = {}, combatReceived = 0, normalReceived = 0, bytes = 0,
        }
        return true
    elseif opcode == "STATE_ITEM" then
        local f = self:Split(payload, "~", true)
        if #f ~= 5 then return true end
        local token, name = self:Trim(f[1]), self:NormalizeName(self:DecodeField(f[2]))
        local scope, index, strategy = self:Upper(f[3]), tonumber(f[4]), self:DecodeField(f[5])
        local frame = getFrame(self, token, "STATE_REQUEST")
        local tx = frame and name and frame.active[self:BotKey(name)] or nil
        if not tx or (scope ~= "C" and scope ~= "N") or not index or index < 1 or #strategy > STATE_MAX_STRATEGY_LENGTH then return true end
        local list = scope == "C" and tx.combat or tx.normal
        local expected = scope == "C" and tx.combatExpected or tx.normalExpected
        if index > expected then return true end
        if list[index] == nil then
            list[index] = strategy
            tx.bytes = tx.bytes + #strategy
            if scope == "C" then tx.combatReceived = tx.combatReceived + 1 else tx.normalReceived = tx.normalReceived + 1 end
        end
        if tx.bytes > STATE_MAX_TOTAL_BYTES then self.bridge.frames[token] = nil end
        return true
    elseif opcode == "STATE_END" then
        local f = self:Split(payload, "~", true)
        if #f ~= 4 then return true end
        local token, name = self:Trim(f[1]), self:NormalizeName(self:DecodeField(f[2]))
        local combatCount, normalCount = tonumber(f[3]), tonumber(f[4])
        local frame = getFrame(self, token, "STATE_REQUEST")
        local botKey = name and self:BotKey(name) or nil
        local tx = frame and botKey and frame.active[botKey] or nil
        if not tx or combatCount ~= tx.combatExpected or normalCount ~= tx.normalExpected or tx.combatReceived ~= combatCount or tx.normalReceived ~= normalCount then return true end
        for i = 1, combatCount do if tx.combat[i] == nil then return true end end
        for i = 1, normalCount do if tx.normal[i] == nil then return true end end
        local latest = tonumber(self.bridge.stateLatestOrderByBot[botKey]) or 0
        if (frame.order or 0) >= latest then
            self.bridge.stateLatestOrderByBot[botKey] = frame.order or 0
            commitBotState(self, name, tx.combat, tx.normal, token, "BRIDGE_FRAMED")
        end
        frame.active[botKey] = nil
        if frame.global then
            if not frame.completedBotKeys[botKey] then frame.completedBotKeys[botKey] = true; frame.completedBots = frame.completedBots + 1 end
        else
            finishFrame(self, token)
        end
        return true
    elseif opcode == "STATE_ABORT" then
        local f = self:Split(payload, "~", true)
        local token = self:Trim(f[1])
        local reason = self:DecodeField(f[3] or "UNKNOWN")
        local request = self:FindPendingReadByToken(token)
        if request then self:FailRead(request, "STATE_ABORT:" .. reason) end
        finishFrame(self, token)
        return true
    elseif opcode == "STATES_BEGIN" then
        local f = self:Split(payload, "~", true)
        local frame = getFrame(self, self:Trim(f[1]), "STATE_REQUEST")
        local count = tonumber(f[2])
        if frame and frame.global and count and count >= 0 and count <= STATE_MAX_BOTS then
            frame.begun, frame.expectedBots, frame.completedBots, frame.completedBotKeys = true, count, 0, {}
        end
        return true
    elseif opcode == "STATES_END" then
        local f = self:Split(payload, "~", true)
        local token, sent = self:Trim(f[1]), tonumber(f[2])
        local frame = getFrame(self, token, "STATE_REQUEST")
        if frame and frame.global and sent and sent == frame.expectedBots and frame.completedBots == frame.expectedBots then finishFrame(self, token) end
        return true
    end

    if opcode == "WEAPON_ENCHANT" then
        local f = self:Split(payload, "~", true)
        local token = self:Trim(f[1])
        local frame = getFrame(self, token, "WEAPON_ENCHANT")
        if frame then
            local name = self:NormalizeName(self:DecodeField(f[2])) or frame.botName
            local snapshot = {
                name = name, status = self:Trim(f[3]),
                mainHand = { itemId = tonumber(f[4]) or 0, enchantId = tonumber(f[5]) or 0, duration = tonumber(f[6]) or 0 },
                offHand = { itemId = tonumber(f[7]) or 0, enchantId = tonumber(f[8]) or 0, duration = tonumber(f[9]) or 0 },
            }
            self:CommitData("BOT.WEAPON_ENCHANT", frame.botKey, snapshot, { source = "BRIDGE", token = token })
            finishFrame(self, token)
        end
        return true
    elseif opcode == "TALENT_SPEC_BEGIN" then
        local name, token = self:SplitOnce(payload, "~")
        local frame, decoded = frameForBot(self, token, "TALENT_SPEC_LIST", name)
        if frame then frame.items = {}; frame.current = nil; frame.begun = true; frame.botName = decoded end
        return true
    elseif opcode == "TALENT_SPEC_CURRENT" then
        local f = self:Split(payload, "~", true)
        local frame = frameForBot(self, f[2], "TALENT_SPEC_LIST", f[1])
        if frame and frame.begun and #f >= 6 then
            local slot = tonumber(f[3])
            local tree0, tree1, tree2 = tonumber(f[4]), tonumber(f[5]), tonumber(f[6])
            if slot and slot >= 1 and slot <= 2
                and tree0 and tree0 >= 0 and tree0 <= 255
                and tree1 and tree1 >= 0 and tree1 <= 255
                and tree2 and tree2 >= 0 and tree2 <= 255 then
                local treePoints = { tree0, tree1, tree2 }
                frame.current = {
                    slot = slot,
                    treePoints = treePoints,
                    buildSummary = tostring(tree0) .. "-" .. tostring(tree1) .. "-" .. tostring(tree2),
                }
            end
        end
        return true
    elseif opcode == "TALENT_SPEC_ITEM" then
        local f = self:Split(payload, "~", true)
        local frame, name = frameForBot(self, f[2], "TALENT_SPEC_LIST", f[1])
        if frame and frame.begun then
            frame.items[#frame.items + 1] = { index = tonumber(f[3]) or 0, name = self:DecodeField(f[4]), build = self:Trim(f[5]) }
        end
        return true
    elseif opcode == "TALENT_SPEC_END" then
        local name, token = self:SplitOnce(payload, "~")
        local frame, decoded = frameForBot(self, token, "TALENT_SPEC_LIST", name)
        if frame and frame.begun then
            table.sort(frame.items, function(a, b) return (a.index or 0) < (b.index or 0) end)
            self:CommitData("BOT.TALENT_SPECS", frame.botKey, {
                name = decoded,
                specs = frame.items,
                current = frame.current and self:Copy(frame.current) or nil,
            }, { source = "BRIDGE", token = frame.token })
            finishFrame(self, frame.token)
        end
        return true
    elseif opcode == "GLYPHS_BEGIN" then
        local name, token = self:SplitOnce(payload, "~")
        local frame, decoded = frameForBot(self, token, "GLYPHS", name)
        if frame then frame.items = {}; frame.begun = true; frame.botName = decoded end
        return true
    elseif opcode == "GLYPHS_ITEM" then
        local f = self:Split(payload, "~", true)
        local frame = frameForBot(self, f[2], "GLYPHS", f[1])
        if frame and frame.begun then
            frame.items[#frame.items + 1] = {
                index = tonumber(f[3]) or 0, itemId = tonumber(f[4]) or 0, glyphId = tonumber(f[5]) or 0,
                spellId = tonumber(f[6]) or 0, type = self:DecodeField(f[7]),
            }
        end
        return true
    elseif opcode == "GLYPHS" then
        local name, rest = self:SplitOnce(payload, "~")
        local token, entries = self:SplitOnce(rest, "~")
        local frame, decoded = frameForBot(self, token, "GLYPHS", name)
        if frame then
            frame.items = {}
            for raw in string.gmatch(entries or "", "([^~]+)") do
                local f = self:Split(raw, ":", true)
                frame.items[#frame.items + 1] = { index = #frame.items + 1, itemId = tonumber(f[1]) or 0, glyphId = tonumber(f[2]) or 0, spellId = tonumber(f[3]) or 0, type = self:DecodeField(f[4]) }
            end
            self:CommitData("BOT.GLYPHS", frame.botKey, { name = decoded, glyphs = frame.items }, { source = "BRIDGE", token = frame.token })
            finishFrame(self, frame.token)
        end
        return true
    elseif opcode == "GLYPHS_END" then
        local name, token = self:SplitOnce(payload, "~")
        local frame, decoded = frameForBot(self, token, "GLYPHS", name)
        if frame then
            table.sort(frame.items, function(a, b) return (a.index or 0) < (b.index or 0) end)
            self:CommitData("BOT.GLYPHS", frame.botKey, { name = decoded, glyphs = frame.items }, { source = "BRIDGE", token = frame.token })
            finishFrame(self, frame.token)
        end
        return true
    end

    if opcode == "INV_BEGIN" then
        local name, token = self:SplitOnce(payload, "~")
        local frame, decoded = frameForBot(self, token, "INVENTORY", name)
        if frame then frame.items = {}; frame.summary = {}; frame.begun = true; frame.botName = decoded end
        return true
    elseif opcode == "INV_SUMMARY" then
        local f = self:Split(payload, "~", true)
        local frame = frameForBot(self, f[2], "INVENTORY", f[1])
        if frame and frame.begun then
            frame.summary = { gold = tonumber(f[3]) or 0, silver = tonumber(f[4]) or 0, copper = tonumber(f[5]) or 0, bagUsed = tonumber(f[6]) or 0, bagTotal = tonumber(f[7]) or 0 }
        end
        return true
    elseif opcode == "INV_ITEM" then
        local f = self:Split(payload, "~", true)
        local frame = frameForBot(self, f[2], "INVENTORY", f[1])
        if frame and frame.begun then
            local item = self:ParseItemLine(self:DecodeField(f[3]), "BRIDGE.INVENTORY")
            item.index = #frame.items + 1
            frame.items[#frame.items + 1] = item
        end
        return true
    elseif opcode == "INV_END" then
        local name, token = self:SplitOnce(payload, "~")
        local frame, decoded = frameForBot(self, token, "INVENTORY", name)
        if frame and frame.begun then
            local snapshot = {
                schemaVersion = 2, name = decoded, summary = frame.summary or {}, items = frame.items or {}, byItemId = self:AggregateItems(frame.items),
                locationModel = "FLAT", hasPhysicalLocations = false, equipmentReadback = false,
                locationFields = { bag = false, slot = false, equipmentSlot = false },
            }
            self:CommitData("BOT.INVENTORY", frame.botKey, snapshot, { source = "BRIDGE", token = frame.token })
            finishFrame(self, frame.token)
        end
        return true
    elseif opcode == "INV_EXACT_BEGIN" then
        local name, token = self:SplitOnce(payload, "~")
        local frame, decoded = frameForBot(self, token, "INVENTORY_EXACT", name)
        if frame then
            frame.botName = decoded
            frame.begun = true
            frame.integrityError = nil
            frame.bags = {}
            frame.items = {}
            frame.itemsByPosition = {}
        end
        return true
    elseif opcode == "INV_BAG" then
        local f = self:Split(payload, "~", true)
        local frame = frameForBot(self, f[2], "INVENTORY_EXACT", f[1])
        if not frame then self:ObserveProtocolExtension(opcode, payload); return true end
        if not frame.begun or #f ~= 7 then frame.integrityError = "INV_BAG_BAD_FRAME"; return true end
        local kind = self:Trim(f[3])
        local bag = parseIntegerRange(f[4], 0, 255)
        local slotStart = parseIntegerRange(f[5], 0, 255)
        local slotCount = parseIntegerRange(f[6], 0, 255)
        local bagItemId = parseIntegerRange(f[7], 0, 4294967295)
        if (kind ~= "BACKPACK" and kind ~= "BAG" and kind ~= "KEYRING") or bag == nil or slotStart == nil or slotCount == nil or bagItemId == nil then
            frame.integrityError = "INV_BAG_BAD_FIELDS"
        else
            frame.bags[#frame.bags + 1] = { kind = kind, bag = bag, slotStart = slotStart, slotCount = slotCount, itemId = bagItemId }
        end
        return true
    elseif opcode == "INV_ITEM_LOC" then
        local f = self:Split(payload, "~", true)
        local frame = frameForBot(self, f[2], "INVENTORY_EXACT", f[1])
        if not frame then self:ObserveProtocolExtension(opcode, payload); return true end
        if not frame.begun or #f ~= 7 then frame.integrityError = "INV_ITEM_LOC_BAD_FRAME"; return true end
        local bag = parseIntegerRange(f[3], 0, 255)
        local slot = parseIntegerRange(f[4], 0, 255)
        local itemId = parseIntegerRange(f[5], 1, 4294967295)
        local count = parseIntegerRange(f[6], 1, 4294967295)
        local soulbound = self:Trim(f[7])
        if bag == nil or slot == nil or itemId == nil or count == nil or (soulbound ~= "0" and soulbound ~= "1") then
            frame.integrityError = "INV_ITEM_LOC_BAD_FIELDS"
        else
            local positionKey = tostring(bag) .. ":" .. tostring(slot)
            if frame.itemsByPosition[positionKey] then
                frame.integrityError = "DUPLICATE_ITEM_POSITION"
            else
                local item = { bag = bag, slot = slot, itemId = itemId, count = count, soulbound = soulbound == "1", locationKnown = true }
                frame.items[#frame.items + 1] = item
                frame.itemsByPosition[positionKey] = item
            end
        end
        return true
    elseif opcode == "INV_EXACT_ERROR" then
        local name, rest = self:SplitOnce(payload, "~")
        local token, reason = self:SplitOnce(rest, "~")
        local frame = frameForBot(self, token, "INVENTORY_EXACT", name)
        if frame then
            frame.integrityError = self:Trim(reason) ~= "" and self:Trim(reason) or "FAILED"
        end
        return true
    elseif opcode == "INV_EXACT_END" then
        local name, token = self:SplitOnce(payload, "~")
        local frame, decoded = frameForBot(self, token, "INVENTORY_EXACT", name)
        if frame then
            if frame.begun and not frame.integrityError then
                local used, capacity = #frame.items, 0
                for _, bag in ipairs(frame.bags or {}) do capacity = capacity + (tonumber(bag.slotCount) or 0) end
                local snapshot = {
                    schemaVersion = 1, name = decoded, bags = frame.bags or {}, items = frame.items or {}, itemsByPosition = frame.itemsByPosition or {},
                    summary = { bagUsed = used, bagTotal = capacity, bagFree = math.max(0, capacity - used) },
                    locationModel = "PHYSICAL", hasPhysicalLocations = true, exactStackAddressable = true, equipmentReadback = false,
                    locationFields = { bag = true, slot = true, soulbound = true, equipmentSlot = false },
                }
                self:CommitData("BOT.INVENTORY_EXACT", frame.botKey, snapshot, { source = "BRIDGE", token = frame.token })
            else
                local request = self.FindPendingReadByToken and self:FindPendingReadByToken(frame.token) or nil
                if request and self.FailRead then self:FailRead(request, frame.integrityError or "INV_EXACT_INCOMPLETE") end
            end
            finishFrame(self, frame.token)
        end
        return true
    elseif opcode == "INV_EQUIP_LOC" then
        self:ObserveProtocolExtension(opcode, payload)
        return true
    end

    if opcode == "BUYBACK_BEGIN" then
        local f = self:Split(payload, "~", true)
        local frame, decoded = frameForBot(self, f[2], "BUYBACK", f[1])
        if frame then
            local expected = #f == 3 and parseIntegerRange(f[3], 0, 12) or nil
            frame.botName = decoded
            frame.begun = expected ~= nil
            frame.expectedCount = expected
            frame.items = {}
            frame.seenSlots = {}
            frame.integrityError = expected == nil and "BUYBACK_BEGIN_BAD_FRAME" or nil
        end
        return true
    elseif opcode == "BUYBACK_ITEM" then
        local f = self:Split(payload, "~", true)
        local frame = frameForBot(self, f[2], "BUYBACK", f[1])
        if not frame then self:ObserveProtocolExtension(opcode, payload); return true end
        if not frame.begun or #f ~= 7 then frame.integrityError = "BUYBACK_ITEM_BAD_FRAME"; return true end
        local slot = parseIntegerRange(f[3], 74, 85)
        local itemId = parseIntegerRange(f[4], 1, 4294967295)
        local count = parseIntegerRange(f[5], 1, 1000)
        local price = parseIntegerRange(f[6], 0, 4294967295)
        local timestamp = parseIntegerRange(f[7], 0, 4294967295)
        if slot == nil or itemId == nil or count == nil or price == nil or timestamp == nil then
            frame.integrityError = "BUYBACK_ITEM_BAD_FIELDS"
        elseif frame.seenSlots[slot] then
            frame.integrityError = "BUYBACK_DUPLICATE_SLOT"
        else
            frame.seenSlots[slot] = true
            frame.items[#frame.items + 1] = { slot = slot, itemId = itemId, count = count, price = price, timestamp = timestamp }
        end
        return true
    elseif opcode == "BUYBACK_END" then
        local f = self:Split(payload, "~", true)
        local frame, decoded = frameForBot(self, f[2], "BUYBACK", f[1])
        if frame then
            local status = #f == 5 and self:Upper(f[3]) or ""
            local reason = #f == 5 and self:DecodeField(f[4]) or "BAD_RESPONSE"
            local count = #f == 5 and parseIntegerRange(f[5], 0, 12) or nil
            local validStatus = status == "OK" or status == "ERR"
            if not validStatus or count == nil then frame.integrityError = frame.integrityError or "BUYBACK_END_BAD_FRAME" end
            if status == "OK" then
                if not frame.begun or frame.expectedCount ~= count or #frame.items ~= count then frame.integrityError = frame.integrityError or "BUYBACK_COUNT_MISMATCH" end
            elseif status == "ERR" then
                if count ~= 0 then frame.integrityError = frame.integrityError or "BUYBACK_ERROR_COUNT_INVALID" end
                frame.items = {}
            end
            if not frame.integrityError then
                table.sort(frame.items, function(a, b)
                    if (tonumber(a.timestamp) or 0) == (tonumber(b.timestamp) or 0) then return (tonumber(a.slot) or 0) > (tonumber(b.slot) or 0) end
                    return (tonumber(a.timestamp) or 0) > (tonumber(b.timestamp) or 0)
                end)
                self:CommitData("BOT.BUYBACK", frame.botKey, {
                    schemaVersion = 1, name = decoded, status = status, reason = reason or "UNKNOWN", items = frame.items or {},
                    count = #frame.items, slotModel = "VENDOR_BUYBACK_74_TO_85",
                }, { source = "BRIDGE", token = frame.token })
            else
                local request = self.FindPendingReadByToken and self:FindPendingReadByToken(frame.token) or nil
                if request and self.FailRead then self:FailRead(request, frame.integrityError or "BUYBACK_INCOMPLETE") end
            end
            finishFrame(self, frame.token)
        end
        return true
    end

    if opcode == "BANK_BEGIN" or opcode == "GBANK_BEGIN" then
        local name, token = self:SplitOnce(payload, "~")
        local kind = opcode == "BANK_BEGIN" and "BANK" or "GBANK"
        local frame, decoded = frameForBot(self, token, kind, name)
        if frame then frame.items = {}; frame.error = nil; frame.rights = nil; frame.begun = true; frame.botName = decoded end
        return true
    elseif opcode == "BANK_ITEM" or opcode == "GBANK_ITEM" then
        local f = self:Split(payload, "~", true)
        local kind = opcode == "BANK_ITEM" and "BANK" or "GBANK"
        local frame = frameForBot(self, f[2], kind, f[1])
        if frame and frame.begun then
            local item = self:ParseItemLine(self:DecodeField(f[3]), kind == "BANK" and "BRIDGE.BANK" or "BRIDGE.GUILD_BANK")
            item.index = #frame.items + 1
            frame.items[#frame.items + 1] = item
        end
        return true
    elseif opcode == "BANK_ERROR" or opcode == "GBANK_ERROR" then
        local f = self:Split(payload, "~", true)
        local kind = opcode == "BANK_ERROR" and "BANK" or "GBANK"
        local frame = frameForBot(self, f[2], kind, f[1])
        if frame then frame.error = self:DecodeField(f[3]) end
        return true
    elseif opcode == "GBANK_RIGHTS" then
        local f = self:Split(payload, "~", true)
        local frame = frameForBot(self, f[2], "GBANK", f[1])
        if frame then frame.rights = { canWithdraw = self:ToBoolean(f[3]), remaining = tonumber(f[4]) or 0 } end
        return true
    elseif opcode == "BANK_END" or opcode == "GBANK_END" then
        local name, token = self:SplitOnce(payload, "~")
        local kind = opcode == "BANK_END" and "BANK" or "GBANK"
        local domain = opcode == "BANK_END" and "BOT.BANK" or "BOT.GUILD_BANK"
        local frame, decoded = frameForBot(self, token, kind, name)
        if frame and frame.begun then
            local snapshot = {
                name = decoded, items = frame.items or {}, byItemId = self:AggregateItems(frame.items), error = frame.error,
                rights = frame.rights, locationModel = "FLAT", hasPhysicalLocations = false,
            }
            self:CommitData(domain, frame.botKey, snapshot, { source = "BRIDGE", token = frame.token })
            finishFrame(self, frame.token)
        end
        return true
    end

    if opcode == "SB_BEGIN" then
        local name, token = self:SplitOnce(payload, "~")
        local frame, decoded = frameForBot(self, token, "SPELLBOOK", name)
        if frame then frame.spellIds = {}; frame.begun = true; frame.botName = decoded end
        return true
    elseif opcode == "SB_ITEM" then
        local f = self:Split(payload, "~", true)
        local frame = frameForBot(self, f[2], "SPELLBOOK", f[1])
        if frame and frame.begun then
            local id = tonumber(f[3]) or 0
            if id > 0 then frame.spellIds[#frame.spellIds + 1] = id end
        end
        return true
    elseif opcode == "SB_END" then
        local name, token = self:SplitOnce(payload, "~")
        local frame, decoded = frameForBot(self, token, "SPELLBOOK", name)
        if frame and frame.begun then
            local byId = {}; for _, id in ipairs(frame.spellIds) do byId[id] = true end
            self:CommitData("BOT.SPELLBOOK", frame.botKey, { name = decoded, spellIds = frame.spellIds, byId = byId }, { source = "BRIDGE", token = frame.token })
            finishFrame(self, frame.token)
        end
        return true
    end

    if opcode == "BOT_SKILLS_BEGIN" or opcode == "BOT_REPUTATIONS_BEGIN" or opcode == "BOT_EMBLEMS_BEGIN" then
        local name, token = self:SplitOnce(payload, "~")
        local kind = opcode == "BOT_SKILLS_BEGIN" and "BOT_SKILLS" or (opcode == "BOT_REPUTATIONS_BEGIN" and "BOT_REPUTATIONS" or "BOT_EMBLEMS")
        local frame, decoded = frameForBot(self, token, kind, name)
        if frame then frame.items = {}; frame.money = nil; frame.begun = true; frame.botName = decoded end
        return true
    elseif opcode == "BOT_SKILLS_ITEM" then
        local f = self:Split(payload, "~", true)
        local frame = frameForBot(self, f[2], "BOT_SKILLS", f[1])
        if frame and frame.begun then
            frame.items[#frame.items + 1] = { category = self:DecodeField(f[3]), skillId = tonumber(f[4]) or 0, key = self:DecodeField(f[5]), name = self:DecodeField(f[6]), value = tonumber(f[7]) or 0, max = tonumber(f[8]) or 0 }
        end
        return true
    elseif opcode == "BOT_REPUTATION_ITEM" then
        local f = self:Split(payload, "~", true)
        local frame = frameForBot(self, f[2], "BOT_REPUTATIONS", f[1])
        if frame and frame.begun then
            frame.items[#frame.items + 1] = { factionId = tonumber(f[3]) or 0, name = self:DecodeField(f[4]), rank = tonumber(f[5]) or 0, value = tonumber(f[6]) or 0, max = tonumber(f[7]) or 0 }
        end
        return true
    elseif opcode == "BOT_EMBLEM_ITEM" then
        local f = self:Split(payload, "~", true)
        local frame = frameForBot(self, f[2], "BOT_EMBLEMS", f[1])
        if frame and frame.begun then frame.items[#frame.items + 1] = { itemId = tonumber(f[3]) or 0, count = tonumber(f[4]) or 0 } end
        return true
    elseif opcode == "BOT_EMBLEMS_MONEY" then
        local f = self:Split(payload, "~", true)
        local frame = frameForBot(self, f[2], "BOT_EMBLEMS", f[1])
        if frame then frame.money = tonumber(f[3]) or 0 end
        return true
    elseif opcode == "BOT_SKILLS_END" or opcode == "BOT_REPUTATIONS_END" or opcode == "BOT_EMBLEMS_END" then
        local name, token = self:SplitOnce(payload, "~")
        local kind, domain
        if opcode == "BOT_SKILLS_END" then kind, domain = "BOT_SKILLS", "BOT.SKILLS"
        elseif opcode == "BOT_REPUTATIONS_END" then kind, domain = "BOT_REPUTATIONS", "BOT.REPUTATIONS"
        else kind, domain = "BOT_EMBLEMS", "BOT.EMBLEMS" end
        local frame, decoded = frameForBot(self, token, kind, name)
        if frame and frame.begun then
            local snapshot = { name = decoded, items = frame.items }
            if kind == "BOT_EMBLEMS" then snapshot.money = frame.money end
            self:CommitData(domain, frame.botKey, snapshot, { source = "BRIDGE", token = frame.token })
            finishFrame(self, frame.token)
        end
        return true
    end

    if opcode == "PROFESSION_RECIPES_BEGIN" then
        local f = self:Split(payload, "~", true)
        local frame, decoded = frameForBot(self, f[2], "PROFESSION_RECIPES", f[1])
        if frame and tonumber(f[3]) == frame.skillId then frame.recipes = {}; frame.begun = true; frame.botName = decoded end
        return true
    elseif opcode == "PROFESSION_RECIPES_ITEM" then
        local f = self:Split(payload, "~", true)
        local frame = frameForBot(self, f[2], "PROFESSION_RECIPES", f[1])
        local skillId = tonumber(f[3]) or 0
        if frame and frame.begun and skillId == frame.skillId then
            frame.recipes[#frame.recipes + 1] = {
                skillId = skillId, spellId = tonumber(f[4]) or 0, itemId = tonumber(f[5]) or 0,
                difficulty = self:DecodeField(f[6]), craftable = tonumber(f[7]) or 0,
                materials = parseRecipeMaterials(self, self:DecodeField(f[8])),
            }
        end
        return true
    elseif opcode == "PROFESSION_RECIPES_END" then
        local f = self:Split(payload, "~", true)
        local frame, decoded = frameForBot(self, f[2], "PROFESSION_RECIPES", f[1])
        local skillId = tonumber(f[3]) or 0
        if frame and frame.begun and skillId == frame.skillId then
            local targetKey = frame.botKey .. "|" .. tostring(skillId)
            self:CommitData("BOT.PROFESSION_RECIPES", targetKey, { name = decoded, skillId = skillId, recipes = frame.recipes }, { source = "BRIDGE", token = frame.token })
            finishFrame(self, frame.token)
        end
        return true
    end

    if opcode == "OUTFITS_BEGIN" then
        local name, token = self:SplitOnce(payload, "~")
        local frame, decoded = frameForBot(self, token, "OUTFITS", name)
        if frame then frame.lines = {}; frame.begun = true; frame.botName = decoded end
        return true
    elseif opcode == "OUTFITS_ITEM" then
        local f = self:Split(payload, "~", true)
        local frame = frameForBot(self, f[2], "OUTFITS", f[1])
        if frame and frame.begun then frame.lines[#frame.lines + 1] = self:DecodeField(f[3]) end
        return true
    elseif opcode == "OUTFITS_END" then
        local name, token = self:SplitOnce(payload, "~")
        local frame, decoded = frameForBot(self, token, "OUTFITS", name)
        if frame and frame.begun then
            self:CommitData("BOT.OUTFITS", frame.botKey, { name = decoded, lines = frame.lines }, { source = "BRIDGE", token = frame.token })
            finishFrame(self, frame.token)
        end
        return true
    end

    if opcode == "TRAINER_BEGIN" then
        local f = self:Split(payload, "~", true)
        local frame, decoded = frameForBot(self, f[2], "TRAINER", f[1])
        if frame then
            frame.trainerEntry = tonumber(f[3]) or 0; frame.trainerName = self:DecodeField(f[4]); frame.spells = {}; frame.error = nil; frame.begun = true; frame.botName = decoded
        end
        return true
    elseif opcode == "TRAINER_ITEM" then
        local f = self:Split(payload, "~", true)
        local frame = frameForBot(self, f[2], "TRAINER", f[1])
        if frame and frame.begun then
            frame.spells[#frame.spells + 1] = { trainerEntry = tonumber(f[3]) or 0, spellId = tonumber(f[4]) or 0, cost = tonumber(f[5]) or 0, canAfford = self:ToBoolean(f[6]) }
        end
        return true
    elseif opcode == "TRAINER_ERROR" then
        local f = self:Split(payload, "~", true)
        local frame = frameForBot(self, f[2], "TRAINER", f[1])
        if frame then frame.trainerEntry = tonumber(f[3]) or frame.trainerEntry; frame.error = self:DecodeField(f[4]) end
        return true
    elseif opcode == "TRAINER_END" then
        local f = self:Split(payload, "~", true)
        local frame, decoded = frameForBot(self, f[2], "TRAINER", f[1])
        if frame and frame.begun then
            local snapshot = { name = decoded, trainerEntry = tonumber(f[3]) or frame.trainerEntry or 0, trainerName = self:DecodeField(f[4]), spells = frame.spells, error = frame.error }
            self:CommitData("BOT.TRAINER", frame.botKey, snapshot, { source = "BRIDGE", token = frame.token })
            finishFrame(self, frame.token)
        end
        return true
    end

    if opcode == "QUESTS_BEGIN" then
        local f = self:Split(payload, "~", true)
        local token = self:Trim(f[2])
        local frame = getFrame(self, token, "QUESTS")
        local name = self:NormalizeName(self:DecodeField(f[1]))
        if frame and name then
            local key = self:BotKey(name)
            frame.bots[key] = { name = name, mode = self:Upper(f[3]), items = {}, incomplete = {}, completed = {}, byId = {}, begun = true }
        end
        return true
    elseif opcode == "QUESTS_ITEM" then
        local f = self:Split(payload, "~", true)
        local frame = getFrame(self, self:Trim(f[2]), "QUESTS")
        local name = self:NormalizeName(self:DecodeField(f[1]))
        local buffer = frame and name and frame.bots[self:BotKey(name)] or nil
        if buffer and buffer.begun then
            local status, questId, questName = self:Upper(f[4]), tonumber(f[5]) or 0, self:DecodeField(f[6])
            if questId > 0 and (status == "I" or status == "C") then
                local item = { questId = questId, id = questId, name = questName ~= "" and questName or tostring(questId), status = status }
                buffer.items[#buffer.items + 1] = item; buffer.byId[questId] = item
                if status == "I" then buffer.incomplete[#buffer.incomplete + 1] = item else buffer.completed[#buffer.completed + 1] = item end
            end
        end
        return true
    elseif opcode == "QUESTS_END" then
        local f = self:Split(payload, "~", true)
        local token = self:Trim(f[2])
        local frame = getFrame(self, token, "QUESTS")
        local name = self:NormalizeName(self:DecodeField(f[1]))
        local key = name and self:BotKey(name) or nil
        local buffer = frame and key and frame.bots[key] or nil
        if buffer and buffer.begun then
            local snapshot = { name = name, mode = buffer.mode, items = buffer.items, incomplete = buffer.incomplete, completed = buffer.completed, byId = buffer.byId }
            self:CommitData("BOT.QUESTS", key, snapshot, { source = "BRIDGE", token = token })
            buffer.complete = true
        end
        return true
    elseif opcode == "QUESTS_DONE" then
        local token = self:SplitOnce(payload, "~")
        finishFrame(self, self:Trim(token))
        return true
    end

    if opcode == "GAMEOBJECTS_BEGIN" then
        local name, token = self:SplitOnce(payload, "~")
        local frame = getFrame(self, self:Trim(token), "GAMEOBJECTS")
        name = self:NormalizeName(self:DecodeField(name))
        if frame and name then frame.bots[self:BotKey(name)] = { name = name, lines = {}, begun = true } end
        return true
    elseif opcode == "GAMEOBJECTS_ITEM" then
        local f = self:Split(payload, "~", true)
        local frame = getFrame(self, self:Trim(f[2]), "GAMEOBJECTS")
        local name = self:NormalizeName(self:DecodeField(f[1]))
        local buffer = frame and name and frame.bots[self:BotKey(name)] or nil
        if buffer and buffer.begun then buffer.lines[#buffer.lines + 1] = self:DecodeField(f[3]) end
        return true
    elseif opcode == "GAMEOBJECTS_END" then
        local name, token = self:SplitOnce(payload, "~")
        local frame = getFrame(self, self:Trim(token), "GAMEOBJECTS")
        name = self:NormalizeName(self:DecodeField(name))
        local key = name and self:BotKey(name) or nil
        local buffer = frame and key and frame.bots[key] or nil
        if buffer and buffer.begun then
            self:CommitData("BOT.GAMEOBJECTS", key, { name = name, lines = buffer.lines }, { source = "BRIDGE", token = frame.token })
            buffer.complete = true
        end
        return true
    elseif opcode == "GAMEOBJECTS_DONE" then
        finishFrame(self, self:Trim(payload))
        return true
    end

    if opcode == "FORMATIONS_BEGIN" then
        local f = self:Split(payload, "~", true)
        local frame = getFrame(self, self:Trim(f[1]), "FORMATIONS")
        if frame then frame.expected = tonumber(f[2]) or 0; frame.items = {}; frame.begun = true end
        return true
    elseif opcode == "FORMATIONS_ITEM" then
        local f = self:Split(payload, "~", true)
        local frame = getFrame(self, self:Trim(f[1]), "FORMATIONS")
        if frame and frame.begun then frame.items[#frame.items + 1] = { botName = self:DecodeField(f[2]), formation = self:Lower(self:DecodeField(f[3])) } end
        return true
    elseif opcode == "FORMATIONS_END" then
        local f = self:Split(payload, "~", true)
        local frame = getFrame(self, self:Trim(f[1]), "FORMATIONS")
        if frame and frame.begun then
            table.sort(frame.items, function(a, b) return self:Lower(a.botName) < self:Lower(b.botName) end)
            self:CommitData("GROUP.FORMATIONS", "GLOBAL", { expected = frame.expected, sent = tonumber(f[2]) or #frame.items, items = frame.items }, { source = "BRIDGE", token = frame.token })
            finishFrame(self, frame.token)
        end
        return true
    end

    if opcode == "STRATEGY_ACK" then
        local f = self:Split(payload, "~", true)
        local token = self:Trim(f[3])
        if self.HandleBridgeActionResult then
            self:HandleBridgeActionResult(token, {
                opcode = opcode, scope = self:Upper(f[1]), target = self:DecodeField(f[2]), stateScope = self:Upper(f[4]),
                matched = tonumber(f[5]) or 0, succeeded = tonumber(f[6]) or 0, failed = tonumber(f[7]) or 0, reason = self:DecodeField(f[8]),
                success = (tonumber(f[6]) or 0) > 0 and (tonumber(f[7]) or 0) == 0,
            })
        end
        return true
    elseif opcode == "FORMATION_ACK" then
        local f = self:Split(payload, "~", true)
        local token = self:Trim(f[3])
        if self.HandleBridgeActionResult then
            self:HandleBridgeActionResult(token, { opcode = opcode, scope = self:Upper(f[1]), target = self:DecodeField(f[2]), succeeded = tonumber(f[4]) or 0, failed = tonumber(f[5]) or 0, formation = self:DecodeField(f[6]), success = (tonumber(f[4]) or 0) > 0 and (tonumber(f[5]) or 0) == 0 })
        end
        return true
    elseif opcode == "RTI_ACK" or opcode == "COMBAT_ACK" or opcode == "POSITION_ACK" or opcode == "LOOT_ACK" then
        local f = self:Split(payload, "~", true)
        local token = self:Trim(f[3])
        local executed = tonumber(f[4]) or 0
        if self.HandleBridgeActionResult then self:HandleBridgeActionResult(token, { opcode = opcode, scope = self:Upper(f[1]), target = self:DecodeField(f[2]), executed = executed, command = self:DecodeField(f[5]), success = executed > 0 }) end
        return true
    elseif opcode == "OUTFITS_CMD" then
        local f = self:Split(payload, "~", true)
        local token, result = self:Trim(f[2]), self:Trim(f[3])
        if self.HandleBridgeActionResult then self:HandleBridgeActionResult(token, { opcode = opcode, botName = self:DecodeField(f[1]), result = result, success = resultIsSuccess(result) }) end
        return true
    elseif opcode == "TRAINER_LEARN" then
        local f = self:Split(payload, "~", true)
        local token, result = self:Trim(f[2]), self:Trim(f[5])
        if self.HandleBridgeActionResult then self:HandleBridgeActionResult(token, { opcode = opcode, botName = self:DecodeField(f[1]), trainerEntry = tonumber(f[3]) or 0, spellId = self:DecodeField(f[4]), result = result, reason = self:DecodeField(f[6]), learnedCount = tonumber(f[7]) or 0, spent = tonumber(f[8]) or 0, success = resultIsSuccess(result) }) end
        return true
    elseif opcode == "PROFESSION_RECIPE_CRAFT" then
        local f = self:Split(payload, "~", true)
        local token, result = self:Trim(f[2]), self:Trim(f[6])
        if self.HandleBridgeActionResult then self:HandleBridgeActionResult(token, { opcode = opcode, botName = self:DecodeField(f[1]), skillId = tonumber(f[3]) or 0, spellId = tonumber(f[4]) or 0, itemId = tonumber(f[5]) or 0, result = result, reason = self:DecodeField(f[7]), success = resultIsSuccess(result) }) end
        return true
    elseif opcode == "INVENTORY_ITEM_EQUIP" then
        local f = self:Split(payload, "~", true)
        if #f ~= 7 then return true end
        local token = self:Trim(f[2])
        if self.HandleBridgeActionResult then
            self:HandleBridgeActionResult(token, {
                opcode = opcode, botName = self:DecodeField(f[1]), status = self:Upper(f[3]), reason = self:DecodeField(f[4]),
                srcBag = tonumber(f[5]), srcSlot = tonumber(f[6]), dstSlot = tonumber(f[7]), success = self:Upper(f[3]) == "OK",
            })
        end
        return true
    elseif opcode == "INVENTORY_ITEM_USE" or opcode == "INVENTORY_ITEM_DESTROY" then
        local f = self:Split(payload, "~", true)
        if #f ~= 7 then return true end
        local token = self:Trim(f[2])
        if self.HandleBridgeActionResult then
            self:HandleBridgeActionResult(token, {
                opcode = opcode, botName = self:DecodeField(f[1]), status = self:Upper(f[3]), reason = self:DecodeField(f[4]),
                srcBag = tonumber(f[5]), srcSlot = tonumber(f[6]), itemId = tonumber(f[7]), success = self:Upper(f[3]) == "OK",
            })
        end
        return true
    elseif opcode == "INVENTORY_ITEM_SELL" then
        local f = self:Split(payload, "~", true)
        if #f ~= 8 then return true end
        local token = self:Trim(f[2])
        if self.HandleBridgeActionResult then
            self:HandleBridgeActionResult(token, {
                opcode = opcode, botName = self:DecodeField(f[1]), status = self:Upper(f[3]), reason = self:DecodeField(f[4]),
                srcBag = tonumber(f[5]), srcSlot = tonumber(f[6]), itemId = tonumber(f[7]), soldCount = tonumber(f[8]), success = self:Upper(f[3]) == "OK",
            })
        end
        return true
    elseif opcode == "INVENTORY_ITEM_TRADE" then
        local f = self:Split(payload, "~", true)
        if #f ~= 9 then return true end
        local token = self:Trim(f[2])
        if self.HandleBridgeActionResult then
            self:HandleBridgeActionResult(token, {
                opcode = opcode, botName = self:DecodeField(f[1]), status = self:Upper(f[3]), reason = self:DecodeField(f[4]),
                srcBag = tonumber(f[5]), srcSlot = tonumber(f[6]), itemId = tonumber(f[7]), srcCount = tonumber(f[8]), tradeSlot = tonumber(f[9]),
                transferCompleted = false, success = self:Upper(f[3]) == "OK",
            })
        end
        return true
    elseif opcode == "INVENTORY_ITEM_MOVE" then
        local f = self:Split(payload, "~", true)
        if #f ~= 8 then return true end
        local token = self:Trim(f[2])
        if self.HandleBridgeActionResult then
            self:HandleBridgeActionResult(token, {
                opcode = opcode, botName = self:DecodeField(f[1]), status = self:Upper(f[3]), reason = self:DecodeField(f[4]),
                srcBag = tonumber(f[5]), srcSlot = tonumber(f[6]), dstBag = tonumber(f[7]), dstSlot = tonumber(f[8]),
                success = self:Upper(f[3]) == "OK",
            })
        end
        return true
    elseif opcode == "INVENTORY_ITEM_UNEQUIP" then
        local f = self:Split(payload, "~", true)
        if #f ~= 6 then return true end
        local token = self:Trim(f[2])
        if self.HandleBridgeActionResult then
            self:HandleBridgeActionResult(token, {
                opcode = opcode, botName = self:DecodeField(f[1]), status = self:Upper(f[3]), reason = self:DecodeField(f[4]),
                srcSlot = tonumber(f[5]), itemId = tonumber(f[6]), success = self:Upper(f[3]) == "OK",
            })
        end
        return true
    elseif opcode == "ITEM_DEPOSIT_EXACT" then
        local f = self:Split(payload, "~", true)
        if #f ~= 10 then return true end
        local token = self:Trim(f[2])
        if self.HandleBridgeActionResult then
            self:HandleBridgeActionResult(token, {
                opcode = opcode, botName = self:DecodeField(f[1]), status = self:Upper(f[3]), reason = self:DecodeField(f[4]), action = self:Upper(f[5]),
                srcBag = tonumber(f[6]), srcSlot = tonumber(f[7]), itemId = tonumber(f[8]), srcCount = tonumber(f[9]), movedCount = tonumber(f[10]),
                success = self:Upper(f[3]) == "OK",
            })
        end
        return true
    elseif opcode == "BUYBACK_RESULT" then
        local f = self:Split(payload, "~", true)
        if #f ~= 8 then return true end
        local token = self:Trim(f[2])
        if self.HandleBridgeActionResult then
            self:HandleBridgeActionResult(token, {
                opcode = opcode, botName = self:DecodeField(f[1]), status = self:Upper(f[3]), reason = self:DecodeField(f[4]),
                slot = tonumber(f[5]), itemId = tonumber(f[6]), count = tonumber(f[7]), price = tonumber(f[8]),
                success = self:Upper(f[3]) == "OK",
            })
        end
        return true
    elseif opcode == "INVENTORY_ITEM_ACTION" then
        local f = self:Split(payload, "~", true)
        local token, result = self:Trim(f[2]), self:Trim(f[5])
        if self.HandleBridgeActionResult then self:HandleBridgeActionResult(token, { opcode = opcode, botName = self:DecodeField(f[1]), action = self:Upper(f[3]), itemId = tonumber(f[4]) or 0, result = result, reason = self:DecodeField(f[6]), moved = tonumber(f[7]) or 0, success = resultIsSuccess(result) }) end
        return true
    elseif opcode == "TALENT_SPEC_APPLY_RESULT" then
        local f = self:Split(payload, "~", true)
        if #f ~= 9 then return true end
        local token = self:Trim(f[1])
        local treePoints = { tonumber(f[7]), tonumber(f[8]), tonumber(f[9]) }
        if self.HandleBridgeActionResult then
            self:HandleBridgeActionResult(token, {
                opcode = opcode,
                botName = self:DecodeField(f[2]),
                status = self:Upper(f[3]),
                reason = self:DecodeField(f[4]),
                slot = tonumber(f[5]),
                specIndex = tonumber(f[6]),
                treePoints = treePoints,
                buildSummary = (treePoints[1] and treePoints[2] and treePoints[3]) and (tostring(treePoints[1]) .. "-" .. tostring(treePoints[2]) .. "-" .. tostring(treePoints[3])) or nil,
                success = self:Upper(f[3]) == "OK",
            })
        end
        return true
    elseif opcode == "ERR" then
        local f = self:Split(payload, "~", true)
        local requestType = self:Upper(self:DecodeField(f[2] or ""))
        local token = self:Trim(f[3] or f[2] or "")
        local reason = self:DecodeField(f[4] or f[#f] or "BRIDGE_ERROR")
        if self.HandleBotLifecycleProtocolError and self:HandleBotLifecycleProtocolError(requestType, token, reason) then
            self.bridge.lastError = reason
            return true
        end
        local request = self:FindPendingReadByToken(token)
        if request then self:FailRead(request, reason) end
        if token ~= "" then finishFrame(self, token) end
        if self.HandleBridgeActionResult and token ~= "" then self:HandleBridgeActionResult(token, { opcode = opcode, success = false, reason = reason, error = true }) end
        self.bridge.lastError = reason
        return true
    end

    return false
end
