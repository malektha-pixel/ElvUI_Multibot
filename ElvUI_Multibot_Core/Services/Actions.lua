local _, MB = ...

local FORMATIONS = { arrow = true, queue = true, near = true, melee = true, line = true, circle = true, chaos = true, shield = true }
local ITEM_ACTIONS = {
    BANK_DEPOSIT = true, BANK_WITHDRAW = true, GBANK_DEPOSIT = true, GBANK_WITHDRAW = true, BUY_ITEM = true,
    SELL_GREY = true, SELL_VENDOR = true,
}
local ITEM_ACTION_ZERO_ID = { SELL_GREY = true, SELL_VENDOR = true }
local ITEM_ACTION_CAPABILITY = {
    SELL_GREY = "INVENTORY_BULK_SELL_V1", SELL_VENDOR = "INVENTORY_BULK_SELL_V1",
}
local ITEM_NATIVE_CAPABILITY = {
    EQUIP = "ITEM_EQUIP_V1", USE = "ITEM_USE_V1", SELL = "ITEM_SELL_SINGLE_V1",
    DESTROY = "ITEM_DESTROY_V1", GIVE = "ITEM_TRADE_V1",
}

local function findTalentSpec(snapshot, specIndex)
    if type(snapshot) ~= "table" then return nil end
    specIndex = tonumber(specIndex)
    if specIndex == nil then return nil end
    for _, spec in ipairs(snapshot.specs or {}) do
        if tonumber(spec.index) == specIndex then return spec end
    end
    return nil
end

local function normalizeTalentSlot(self, value)
    if value == nil then return "CURRENT" end
    local raw = self:Upper(value)
    if raw == "" or raw == "CURRENT" then return "CURRENT" end
    local numeric = tonumber(value)
    if numeric and math.floor(numeric) == numeric and (numeric == 1 or numeric == 2) then return numeric end
    return nil
end

local function hasCurrentTarget()
    if type(UnitExists) == "function" then return not not UnitExists("target") end
    if type(UnitName) == "function" then
        local name = UnitName("target")
        return name ~= nil and name ~= "" and name ~= "Unknown Entity"
    end
    return false
end

function MB:TransactionSnapshot(tx)
    if type(tx) ~= "table" then return nil end
    local copy = self:Copy(tx)
    copy.callback = nil
    return copy
end

function MB:SetTransactionState(tx, newState, extra)
    if type(tx) ~= "table" then return false end
    tx.state = newState
    tx.updatedAt = self:Now()
    if type(extra) == "table" then for k, v in pairs(extra) do tx[k] = v end end
    self:Emit("MB_ACTION_STATUS_CHANGED", tx.id, newState, self:TransactionSnapshot(tx))
    if newState == "CONFIRMED" then self:Emit("MB_ACTION_CONFIRMED", tx.id, self:TransactionSnapshot(tx))
    elseif newState == "FAILED" then self:Emit("MB_ACTION_FAILED", tx.id, self:TransactionSnapshot(tx))
    elseif newState == "AMBIGUOUS" then self:Emit("MB_ACTION_AMBIGUOUS", tx.id, self:TransactionSnapshot(tx))
    elseif newState == "CANCELLED" then self:Emit("MB_ACTION_CANCELLED", tx.id, self:TransactionSnapshot(tx))
    elseif newState == "SENT_UNVERIFIED" then self:Emit("MB_ACTION_UNVERIFIED", tx.id, self:TransactionSnapshot(tx)) end
    return true
end

local function validateStrategyChanges(self, changes)
    changes = self:Trim(changes)
    if changes == "" or #changes > 160 then return nil end
    local out = {}
    for operation in string.gmatch(changes .. ",", "(.-),") do
        operation = self:Trim(operation)
        local prefix = string.sub(operation, 1, 1)
        local strategy = self:Lower(string.sub(operation, 2))
        if (prefix ~= "+" and prefix ~= "-") or strategy == "" or #strategy > 96 or string.find(strategy, "[^%w%s%-%_']") then return nil end
        out[#out + 1] = prefix .. strategy
        if #out > 32 then return nil end
    end
    return #out > 0 and table.concat(out, ",") or nil
end

function MB:GetActionAvailability(actionId, targetSpec, args)
    local descriptor = self.actions[actionId]
    local details = {
        actionId = actionId,
        enabled = false,
        reason = nil,
        scope = nil,
        targets = {},
        normalizedArgs = self:Copy(args or {}),
        descriptor = descriptor and self:Copy(descriptor) or nil,
    }
    if not descriptor then details.reason = "UNKNOWN_ACTION"; return details end
    if descriptor.capability and not self:BridgeHasCapability(descriptor.capability) then
        details.reason = "CAPABILITY_UNAVAILABLE"
        return details
    end
    local requestedItemRoute = type(args) == "table" and self:Upper(args.selectedRoute) or ""
    if descriptor.family == "ITEM_SEMANTIC" then
        if requestedItemRoute == "BRIDGE_NATIVE" then
            local capability = ITEM_NATIVE_CAPABILITY[self:Upper(descriptor.semanticKind)]
            if not self.bridge.connected then details.reason = "BRIDGE_NOT_CONNECTED"; return details end
            if not self.bridge.handshakeReady or self.bridge.capabilitiesResolved ~= true then details.reason = "BRIDGE_NOT_READY"; return details end
            if not self:BridgeHasCapability("INVENTORY_EXACT_V1") or not capability or not self:BridgeHasCapability(capability) then
                details.reason = "CAPABILITY_UNAVAILABLE"; return details
            end
        else
            if not self.db or not self.db.chat or not self.db.chat.enabled then details.reason = "CHAT_DISABLED"; return details end
            if type(SendChatMessage) ~= "function" then details.reason = "SEND_CHAT_UNAVAILABLE"; return details end
        end
    elseif descriptor.route == "BRIDGE" then
        if not self.bridge.connected then details.reason = "BRIDGE_NOT_CONNECTED"; return details end
        if not self.bridge.handshakeReady then details.reason = "BRIDGE_NOT_READY"; return details end
    elseif descriptor.route == "CHAT" then
        if not self.db or not self.db.chat or not self.db.chat.enabled then details.reason = "CHAT_DISABLED"; return details end
        if type(SendChatMessage) ~= "function" then details.reason = "SEND_CHAT_UNAVAILABLE"; return details end
        if (descriptor.family == "RTSC_ENABLE" or descriptor.family == "RTSC_PREPARE" or descriptor.family == "RTSC_SELECT" or descriptor.family == "RTSC_SAVE" or descriptor.family == "RTSC_UNSAVE" or descriptor.family == "RTSC_CANCEL")
            and not self:ChatGroupChannel() then details.reason = "GROUP_REQUIRED"; return details end
    end

    local normalized = details.normalizedArgs
    local defaultScope = descriptor.defaultScope or (descriptor.family == "FORMATION" and "GROUP" or "BOT")
    local scope = self:NormalizeScope(normalized.scope, defaultScope)
    normalized.scope = scope
    details.scope = scope
    if not descriptor.scopes[scope] then details.reason = "INVALID_SCOPE"; return details end

    local bots, targetInfo, targetError = self:ResolveTargetSpec(targetSpec)
    if not bots then details.reason = targetError or "INVALID_TARGET_SPEC"; return details end
    details.targetInfo = self:Copy(targetInfo)
    if scope == "BOT" then
        if #bots == 0 then details.reason = "BOT_REQUIRED"; return details end
        if #bots > 1 then details.reason = "MULTIPLE_TARGETS_USE_EXECUTE_SET"; return details end
    elseif scope == "SET" then
        if #bots == 0 then details.reason = "NO_TARGETS"; return details end
    end
    details.targets = self:Copy(bots)

    if descriptor.family == "BOT_LIFECYCLE" then
        if #details.targets ~= 1 then details.reason = "BOT_REQUIRED"; return details end
        local bot = details.targets[1]
        local action = self:Upper(descriptor.lifecycleAction)
        local authority, authorityError = self:GetLifecycleExecutionAuthority(bot)
        if not authority then details.reason = authorityError or "TARGET_RESOLVE_REQUIRED"; return details end
        local guid = tonumber(authority.guid)
        if not guid or guid <= 0 then details.reason = "LIFECYCLE_TARGET_REQUIRED"; return details end
        self.lifecycleByGuid = self.lifecycleByGuid or {}
        if self.lifecycleByGuid[guid] then details.reason = "LIFECYCLE_BUSY"; return details end
        local state = self:Upper(authority.lifecycleState)
        if state == "CONNECTING" or state == "DISCONNECTING" then details.reason = "LIFECYCLE_BUSY"; return details end
        if action == "CONNECT" then
            if state == "ONLINE" then details.reason = "ALREADY_ONLINE"; return details end
            if state ~= "OFFLINE" then details.reason = "LIFECYCLE_STATE_UNKNOWN"; return details end
        elseif action == "DISCONNECT" then
            if state == "OFFLINE" then details.reason = "ALREADY_OFFLINE"; return details end
            if state ~= "ONLINE" then details.reason = "LIFECYCLE_STATE_UNKNOWN"; return details end
        else
            details.reason = "INVALID_LIFECYCLE_ACTION"; return details
        end
        normalized.guid = guid
        normalized.lifecycleAction = action
        normalized.expectedState = action == "CONNECT" and "ONLINE" or "OFFLINE"
        normalized.lifecycleAuthority = authority.source
        normalized.lifecycleAuthoritySessionBound = authority.sessionBound == true
    elseif descriptor.family == "RTI" then
        if descriptor.semanticKind == "ASSIGN_PRIORITY" or descriptor.semanticKind == "ASSIGN_CC" then
            local icon, iconErr = self:NormalizeRTIIcon(normalized.icon)
            if not icon then details.reason = iconErr or "INVALID_RTI_ICON"; return details end
            normalized.icon = icon.key
            normalized.command = descriptor.semanticKind == "ASSIGN_CC" and ("rti cc " .. icon.key) or ("rti " .. icon.key)
        elseif descriptor.semanticKind == "ATTACK_ASSIGNED" then
            normalized.command = "attack rti target"
        elseif descriptor.semanticKind == "PULL_ASSIGNED" then
            normalized.command = "pull rti target"
        else
            normalized.command = self:Trim(normalized.command)
            if normalized.command == "" then details.reason = "COMMAND_REQUIRED"; return details end
        end
    elseif descriptor.family == "TACTICAL_ORDER" then
        local order = self:Upper(normalized.order)
        local orderCommands = {
            FOLLOW = "follow",
            STAY = "stay",
            FLEE = "flee",
            RESET = "reset",
            SUMMON = "do summon",
        }
        if not orderCommands[order] then details.reason = "INVALID_TACTICAL_ORDER"; return details end
        normalized.order = order
        normalized.command = orderCommands[order]
    elseif descriptor.family == "COMBAT" or descriptor.family == "LOOT" or descriptor.family == "POSITION" then
        normalized.command = self:Trim(normalized.command)
        if normalized.command == "" then details.reason = "COMMAND_REQUIRED"; return details end
    elseif descriptor.family == "STRATEGY" then
        normalized.stateScope = self:Upper(normalized.stateScope)
        normalized.changes = validateStrategyChanges(self, normalized.changes)
        if normalized.stateScope ~= "C" and normalized.stateScope ~= "N" then details.reason = "STATE_SCOPE_REQUIRED"; return details end
        if not normalized.changes then details.reason = "INVALID_CHANGES"; return details end
    elseif descriptor.family == "FORMATION" then
        normalized.formation = self:Lower(normalized.formation)
        if scope ~= "GROUP" or not FORMATIONS[normalized.formation] then details.reason = "INVALID_FORMATION"; return details end
    elseif descriptor.family == "OUTFIT" then
        normalized.command = self:Trim(normalized.command)
        normalized.persist = normalized.persist == true or normalized.persist == 1 or normalized.persist == "1"
        if normalized.command == "" then details.reason = "COMMAND_REQUIRED"; return details end
    elseif descriptor.family == "TRAINER_LEARN" then
        normalized.trainerEntry = tonumber(normalized.trainerEntry) or 0
        local requestedSpell = self:Upper(normalized.spellId)
        if requestedSpell == "ALL" then normalized.spellId = "ALL"
        else normalized.spellId = tonumber(normalized.spellId) or 0 end
        if normalized.trainerEntry <= 0 then details.reason = "TRAINER_REQUIRED"; return details end
        if normalized.spellId ~= "ALL" and normalized.spellId <= 0 then details.reason = "SPELL_REQUIRED"; return details end
    elseif descriptor.family == "TALENT_SPEC_APPLY" then
        if #details.targets ~= 1 then details.reason = "BOT_REQUIRED"; return details end
        local bot = details.targets[1]
        if bot.online ~= true then details.reason = "BOT_OFFLINE"; return details end
        normalized.specIndex = tonumber(normalized.specIndex)
        if normalized.specIndex == nil or normalized.specIndex < 0 or normalized.specIndex > 30 or math.floor(normalized.specIndex) ~= normalized.specIndex then
            details.reason = "INVALID_SPEC_INDEX"; return details
        end
        normalized.slot = normalizeTalentSlot(self, normalized.slot)
        if normalized.slot == nil then details.reason = "INVALID_TALENT_SLOT"; return details end

        -- Cached data is advisory for synchronous availability only. Dispatch always
        -- performs a fresh BOT.TALENT_SPECS read before the mutation is sent.
        local talentSnapshot, talentMeta = self:GetData("BOT.TALENT_SPECS", bot.name)
        local fresh = talentSnapshot ~= nil and type(talentMeta) == "table" and talentMeta.stale ~= true and talentMeta.error == nil
        if fresh then
            local selected = findTalentSpec(talentSnapshot, normalized.specIndex)
            if not selected then details.reason = "SPEC_NOT_AVAILABLE"; return details end
            normalized.specName = selected.name
            normalized.specBuild = selected.build
            if normalized.slot == "CURRENT" then
                local currentSlot = talentSnapshot.current and tonumber(talentSnapshot.current.slot)
                if currentSlot ~= 1 and currentSlot ~= 2 then details.reason = "CURRENT_SLOT_UNAVAILABLE"; return details end
                details.resolvedCurrentSlot = currentSlot
            end
            details.talentSpecsFresh = true
        else
            details.requiresFreshTalentSpecs = true
        end
    elseif descriptor.family == "SPELL_EXCLUSION_SET" then
        if #details.targets ~= 1 then details.reason = "BOT_REQUIRED"; return details end
        local bot = details.targets[1]
        if bot.online ~= true then details.reason = "BOT_OFFLINE"; return details end
        normalized.spellId = tonumber(normalized.spellId)
        if not normalized.spellId or normalized.spellId <= 0 or math.floor(normalized.spellId) ~= normalized.spellId then details.reason = "INVALID_SPELL_ID"; return details end
        normalized.enabled = normalized.enabled == true
        if self.GetBotSpellEnabledAvailability then
            local semantic = self:GetBotSpellEnabledAvailability(bot.name, normalized.spellId)
            if not semantic.enabled then details.reason = semantic.reason or "SPELL_EXCLUSION_UNAVAILABLE"; return details end
            details.spellbookValidated = semantic.spellbookValidated
            details.verification = semantic.verification
        end
    elseif descriptor.family == "SPELL_CAST" then
        if #details.targets ~= 1 then details.reason = "BOT_REQUIRED"; return details end
        local bot = details.targets[1]
        if bot.online ~= true then details.reason = "BOT_OFFLINE"; return details end
        normalized.spellId = tonumber(normalized.spellId)
        if not normalized.spellId or normalized.spellId <= 0 or math.floor(normalized.spellId) ~= normalized.spellId then details.reason = "INVALID_SPELL_ID"; return details end
        if self.GetBotSpellCastAvailability then
            local semantic = self:GetBotSpellCastAvailability(bot.name, normalized.spellId, { requireSpellbook = normalized.requireSpellbook == true })
            if not semantic.enabled then details.reason = semantic.reason or "SPELL_CAST_UNAVAILABLE"; return details end
            details.spellbookValidated = semantic.spellbookValidated
        end
    elseif descriptor.family == "CRAFT_RECIPE" then
        normalized.skillId = tonumber(normalized.skillId) or 0
        normalized.spellId = tonumber(normalized.spellId) or 0
        normalized.itemId = tonumber(normalized.itemId) or 0
        if normalized.skillId <= 0 or normalized.spellId <= 0 or normalized.itemId < 0 then details.reason = "INVALID_RECIPE"; return details end
    elseif descriptor.family == "ITEM_ACTION" then
        normalized.action = self:Upper(normalized.action)
        normalized.itemId = tonumber(normalized.itemId) or 0
        normalized.count = tonumber(normalized.count) or 0
        normalized.selectedRoute = self:Upper(normalized.selectedRoute)
        if normalized.selectedRoute == "" then normalized.selectedRoute = "BRIDGE_GENERIC" end
        normalized.sourceBag = normalized.sourceBag ~= nil and tonumber(normalized.sourceBag) or nil
        normalized.sourceSlot = normalized.sourceSlot ~= nil and tonumber(normalized.sourceSlot) or nil
        if not ITEM_ACTIONS[normalized.action] then details.reason = "UNSUPPORTED_ITEM_ACTION"; return details end
        local zeroIdAction = ITEM_ACTION_ZERO_ID[normalized.action] == true
        if (zeroIdAction and (normalized.itemId ~= 0 or normalized.count ~= 0)) or (not zeroIdAction and normalized.itemId <= 0) or normalized.count < 0 then
            details.reason = "INVALID_ITEM_ACTION"; return details
        end
        local requiredCapability = ITEM_ACTION_CAPABILITY[normalized.action]
        if requiredCapability and (not self:BridgeHasCapability("INVENTORY_V1") or not self:BridgeHasCapability(requiredCapability)) then
            details.reason = "CAPABILITY_UNAVAILABLE"; return details
        end
        if normalized.action == "SELL_GREY" or normalized.action == "SELL_VENDOR" then
            if not hasCurrentTarget() then details.reason = "TARGET_REQUIRED"; return details end
        end
        if normalized.selectedRoute ~= "BRIDGE_GENERIC" and normalized.selectedRoute ~= "BRIDGE_EXACT" then details.reason = "INVALID_ITEM_ROUTE"; return details end
        if normalized.selectedRoute == "BRIDGE_EXACT" then
            if normalized.action ~= "BANK_DEPOSIT" and normalized.action ~= "GBANK_DEPOSIT" then details.reason = "INVALID_EXACT_DEPOSIT_ACTION"; return details end
            if normalized.count ~= 0 then details.reason = "EXACT_DEPOSIT_FULL_STACK_ONLY"; return details end
            if not self:BridgeHasCapability("INVENTORY_EXACT_V1") or not self:BridgeHasCapability("ITEM_DEPOSIT_EXACT_V1") then details.reason = "CAPABILITY_UNAVAILABLE"; return details end
        end
    elseif descriptor.family == "ITEM_BUYBACK" then
        normalized.slot = tonumber(normalized.slot)
        normalized.itemId = tonumber(normalized.itemId)
        normalized.count = tonumber(normalized.count)
        normalized.price = tonumber(normalized.price)
        if normalized.slot == nil or normalized.slot < 74 or normalized.slot > 85 or math.floor(normalized.slot) ~= normalized.slot then details.reason = "INVALID_BUYBACK_SLOT"; return details end
        if normalized.itemId == nil or normalized.itemId <= 0 or math.floor(normalized.itemId) ~= normalized.itemId then details.reason = "ITEM_ID_REQUIRED"; return details end
        if normalized.count == nil or normalized.count <= 0 or normalized.count > 1000 or math.floor(normalized.count) ~= normalized.count then details.reason = "INVALID_BUYBACK_COUNT"; return details end
        if normalized.price == nil or normalized.price < 0 or normalized.price > 4294967295 or math.floor(normalized.price) ~= normalized.price then details.reason = "INVALID_BUYBACK_PRICE"; return details end
        if not self:BridgeHasCapability("INVENTORY_EXACT_V1") then details.reason = "CAPABILITY_UNAVAILABLE"; return details end
    elseif descriptor.family == "ITEM_MOVE" then
        normalized.srcBag, normalized.srcSlot = tonumber(normalized.srcBag), tonumber(normalized.srcSlot)
        normalized.srcItemId, normalized.srcCount = tonumber(normalized.srcItemId), tonumber(normalized.srcCount)
        normalized.dstBag, normalized.dstSlot = tonumber(normalized.dstBag), tonumber(normalized.dstSlot)
        normalized.dstItemId, normalized.dstCount = tonumber(normalized.dstItemId) or 0, tonumber(normalized.dstCount) or 0
        if not self:BridgeHasCapability("INVENTORY_EXACT_V1") then details.reason = "CAPABILITY_UNAVAILABLE"; return details end
        if normalized.srcBag == nil or normalized.srcBag < 0 or normalized.srcBag > 255
            or normalized.srcSlot == nil or normalized.srcSlot < 0 or normalized.srcSlot > 255
            or not normalized.srcItemId or normalized.srcItemId <= 0 or not normalized.srcCount or normalized.srcCount <= 0 or normalized.srcCount > 1000
            or normalized.dstBag == nil or normalized.dstBag < 0 or normalized.dstBag > 255
            or normalized.dstSlot == nil or normalized.dstSlot < 0 or normalized.dstSlot > 255
            or normalized.dstItemId < 0 or normalized.dstCount < 0 or normalized.dstCount > 1000
            or ((normalized.dstItemId == 0) ~= (normalized.dstCount == 0))
            or (normalized.srcBag == normalized.dstBag and normalized.srcSlot == normalized.dstSlot) then
            details.reason = "INVALID_ITEM_MOVE"; return details
        end
    elseif descriptor.family == "ITEM_UNEQUIP" then
        normalized.equipmentSlot = tonumber(normalized.equipmentSlot)
        normalized.itemId = tonumber(normalized.itemId)
        if normalized.equipmentSlot == nil or normalized.equipmentSlot < 0 or normalized.equipmentSlot > 18 or math.floor(normalized.equipmentSlot) ~= normalized.equipmentSlot then
            details.reason = "INVALID_EQUIPMENT_SLOT"; return details
        end
        if normalized.itemId == nil or normalized.itemId <= 0 or math.floor(normalized.itemId) ~= normalized.itemId then details.reason = "ITEM_ID_REQUIRED"; return details end
    elseif descriptor.family == "ITEM_SEMANTIC" then
        normalized.itemId = tonumber(normalized.itemId) or 0
        normalized.clientLink = self:Trim(normalized.clientLink)
        normalized.serverLink = self:Trim(normalized.serverLink)
        normalized.itemLink = self:Trim(normalized.itemLink ~= nil and normalized.itemLink or (normalized.clientLink ~= "" and normalized.clientLink or normalized.serverLink))
        normalized.itemLinkSource = self:Trim(normalized.itemLinkSource)
        normalized.selectedRoute = self:Upper(normalized.selectedRoute)
        normalized.sourceBag = normalized.sourceBag ~= nil and tonumber(normalized.sourceBag) or nil
        normalized.sourceSlot = normalized.sourceSlot ~= nil and tonumber(normalized.sourceSlot) or nil
        normalized.confirmed = normalized.confirmed == true
        if normalized.itemId <= 0 then details.reason = "ITEM_ID_REQUIRED"; return details end
        if normalized.selectedRoute ~= "BRIDGE_NATIVE" and normalized.selectedRoute ~= "CHAT" then details.reason = "INVALID_ITEM_ROUTE"; return details end
        if normalized.selectedRoute == "CHAT" then
            local linkId = self:ExtractItemId(normalized.itemLink)
            if normalized.itemLink == "" or not linkId then details.reason = "ITEM_LINK_REQUIRED"; return details end
            if tonumber(linkId) ~= tonumber(normalized.itemId) then details.reason = "ITEM_LINK_MISMATCH"; return details end
        end
        if descriptor.requiresConfirmation and normalized.confirmed ~= true then details.reason = "CONFIRMATION_REQUIRED"; return details end
        if descriptor.requiresMerchantContext then
            local merchantVisible = type(MerchantFrame) == "table" and type(MerchantFrame.IsShown) == "function" and MerchantFrame:IsShown()
            if not merchantVisible then details.reason = "MERCHANT_CONTEXT_REQUIRED"; return details end
        end
    elseif descriptor.family == "QUEST_ABANDON" then
        normalized.questId = tonumber(normalized.questId) or 0
        normalized.questName = self:Trim(normalized.questName)
        normalized.questStatus = self:Upper(normalized.questStatus)
        normalized.confirmed = normalized.confirmed == true
        if normalized.questId <= 0 then details.reason = "QUEST_ID_REQUIRED"; return details end
        if descriptor.requiresConfirmation and normalized.confirmed ~= true then details.reason = "CONFIRMATION_REQUIRED"; return details end
    elseif descriptor.family == "QUEST_NPC" then
        if #details.targets ~= 1 or details.targets[1].online ~= true then
            details.reason = "BOT_OFFLINE"; return details
        end
        if type(UnitExists) ~= "function" or not UnitExists("target") or type(UnitGUID) ~= "function" then
            details.reason = "FRIENDLY_NPC_TARGET_REQUIRED"; return details
        end
        if (type(UnitIsPlayer) == "function" and UnitIsPlayer("target"))
            or (type(UnitCanAttack) == "function" and UnitCanAttack("player", "target")) then
            details.reason = "FRIENDLY_NPC_TARGET_REQUIRED"; return details
        end
        local guid = UnitGUID("target")
        if not guid or guid == "" then details.reason = "TARGET_GUID_UNAVAILABLE"; return details end
        if descriptor.semanticKind == "TALK_TARGET" and normalized.confirmed ~= true then
            details.reason = "CONFIRMATION_REQUIRED"; return details
        end
        normalized.targetGuid = guid
        normalized.targetName = type(UnitName) == "function" and UnitName("target") or nil
        normalized.command = descriptor.semanticKind == "TALK_TARGET" and "talk" or "accept *"
    elseif descriptor.family == "QUEST_ACCEPT_LINK" then
        normalized.questId = tonumber(normalized.questId) or 0
        normalized.questName = self:Trim(normalized.questName)
        normalized.questLevel = tonumber(normalized.questLevel)
        normalized.questLink = self:Trim(normalized.questLink)
        if not self.ParseQuestLink then details.reason = "QUEST_SERVICE_UNAVAILABLE"; return details end
        local parsed, parseErr = self:ParseQuestLink(normalized.questLink)
        if not parsed then details.reason = parseErr or "EXACT_QUEST_LINK_REQUIRED"; return details end
        normalized.questId = parsed.questId
        normalized.questName = parsed.name
        normalized.questLevel = parsed.questLevel
        normalized.questLink = parsed.link
    elseif descriptor.family == "RTSC_PREPARE" then
        normalized.slot = tonumber(normalized.slot) or 0
        if normalized.slot < 0 or normalized.slot > 9 then details.reason = "INVALID_RTSC_SLOT"; return details end
    elseif descriptor.family == "RTSC_GO" or descriptor.family == "RTSC_SAVE" or descriptor.family == "RTSC_UNSAVE" then
        normalized.slot = tonumber(normalized.slot) or 0
        if normalized.slot < 1 or normalized.slot > 9 then details.reason = "INVALID_RTSC_SLOT"; return details end
    elseif descriptor.family == "RTSC_ENABLE" or descriptor.family == "RTSC_SELECT" or descriptor.family == "RTSC_CANCEL" then
        -- No additional arguments.
    end

    details.enabled = true
    return details
end

function MB:CanExecuteAction(actionId, targetSpec, args)
    local details = self:GetActionAvailability(actionId, targetSpec, args)
    return details.enabled == true, details.reason, details
end

function MB:CreateTransaction(originModule, actionId, targetSpec, args, callback)
    self.transactionSequence = self.transactionSequence + 1
    local tx = {
        id = "tx-" .. tostring(self.transactionSequence), originModule = originModule, actionId = actionId,
        targetSpec = self:Copy(targetSpec), args = self:Copy(args or {}), state = "QUEUED",
        createdAt = self:Now(), sessionEpoch = self.sessionEpoch, callback = callback,
    }
    self.transactions[tx.id] = tx
    self.runtime.counters.actionsStarted = self.runtime.counters.actionsStarted + 1
    self:Emit("MB_ACTION_CREATED", tx.id, self:TransactionSnapshot(tx))
    return tx
end

local function actionAckTimeout(self, tx)
    local descriptor = self.actions[tx.actionId] or {}
    local timeout = tonumber(descriptor.timeout) or 8
    tx.ackTimeoutSeconds = timeout
    return timeout
end

local function sendRun(self, tx, family, payload)
    local token = self:NewToken(string.lower(family))
    tx.bridgeToken = token
    tx.sentAt = self:Now()
    tx.expiresAt = tx.sentAt + actionAckTimeout(self, tx)
    self.bridge.actionTokens[token] = tx.id
    self:SetTransactionState(tx, "SENT")
    local ok, err = self:BridgeSend("RUN", payload(token))
    if not ok then
        self.bridge.actionTokens[token] = nil
        self:SetTransactionState(tx, "FAILED", { error = err or "SEND_FAILED", completedAt = self:Now() })
        if type(tx.callback) == "function" then self:SafeCall(tx.callback, self:TransactionSnapshot(tx)) end
        return false, err
    end
    return true, token
end

local function sendChatAction(self, tx, sequence, placement, extraGuard, intervalOverride)
    tx.sentAt = self:Now()
    self:SetTransactionState(tx, "SENT")
    local ok, err = self:ChatSendSequence(sequence, function(result)
        -- A session reset or cancellation may have changed this transaction while
        -- delayed chat steps were still draining.  Never let a late sequence
        -- callback overwrite AMBIGUOUS/CANCELLED/FAILED terminal state.
        if tx.state ~= "SENT" then return end
        tx.completedAt = self:Now()
        tx.result = self:Copy(result or {})
        self.runtime.counters.actionsCompleted = self.runtime.counters.actionsCompleted + 1
        if not result or (tonumber(result.sent) or 0) <= 0 then
            self:SetTransactionState(tx, "FAILED", { error = "CHAT_SEND_FAILED" })
        else
            if placement then
                placement.preparedAt = self:Now()
                placement.transactionId = tx.id
                placement.sendResult = self:Copy(result)
                self:CommitData("CORE.RTSC_PLACEMENT", "GLOBAL", placement, { source = "CHAT", authority = "BEST_EFFORT_SENT" })
                self:Emit("MB_RTSC_PLACEMENT_PREPARED", self:Copy(placement))
            end
            local descriptor = self.actions[tx.actionId]
            if descriptor and descriptor.invalidatesOnSend == true then
                self:ApplyActionInvalidation(tx, result)
            end
            self:SetTransactionState(tx, "SENT_UNVERIFIED")
            if descriptor and descriptor.family == "SPELL_EXCLUSION_SET" and self.RecordSpellExclusionCommand then
                local bot = tx.targets and tx.targets[1]
                if bot then self:RecordSpellExclusionCommand(bot.name, tx.args and tx.args.spellId, tx.args and tx.args.enabled == true, tx.id) end
            end
            if descriptor and descriptor.family == "ITEM_SEMANTIC" and self.BeginItemPostVerification then
                self:BeginItemPostVerification(tx)
            end
        end
        if type(tx.callback) == "function" then self:SafeCall(tx.callback, self:TransactionSnapshot(tx)) end
    end, function()
        if tx.sessionEpoch ~= self.sessionEpoch or tx.state ~= "SENT" then return false end
        if type(extraGuard) == "function" and extraGuard() == false then return false end
        return true
    end, intervalOverride)
    if not ok then
        tx.completedAt = self:Now()
        self.runtime.counters.actionsCompleted = self.runtime.counters.actionsCompleted + 1
        self:SetTransactionState(tx, "FAILED", { error = err or "CHAT_SEND_FAILED" })
        if type(tx.callback) == "function" then self:SafeCall(tx.callback, self:TransactionSnapshot(tx)) end
        return false, err
    end
    return true
end


local function failAsyncItemDispatch(self, tx, reason)
    if not tx or tx.state ~= "DISPATCHING" then return end
    tx.completedAt = self:Now()
    self.runtime.counters.actionsCompleted = self.runtime.counters.actionsCompleted + 1
    self:SetTransactionState(tx, "FAILED", { error = reason or "ITEM_NATIVE_DISPATCH_FAILED" })
    if type(tx.callback) == "function" then self:SafeCall(tx.callback, self:TransactionSnapshot(tx)) end
end

function MB:DispatchNativeItemMutation(tx, bot, source)
    if not tx or not bot or not source or tx.state ~= "DISPATCHING" then return false, "INVALID_ARGUMENT" end
    local action = self:Upper(tx.itemAction or (tx.args and tx.args.action) or (self.actions[tx.actionId] and self.actions[tx.actionId].semanticKind))
    local capability = ITEM_NATIVE_CAPABILITY[action]
    if not capability or not self:BridgeHasCapability("INVENTORY_EXACT_V1") or not self:BridgeHasCapability(capability) then
        return false, "CAPABILITY_UNAVAILABLE"
    end
    local bag, slot, itemId, count = tonumber(source.bag), tonumber(source.slot), tonumber(source.itemId), tonumber(source.count)
    if bag == nil or slot == nil or not itemId or itemId <= 0 or not count or count <= 0 then return false, "INVALID_EXACT_SOURCE" end
    -- Current MultiBot/bridge item mutation contracts bound one physical source
    -- stack to 1..1000 items.  Do not emit a request outside that wire contract.
    if count > 1000 then return false, "SOURCE_COUNT_UNSUPPORTED" end

    local token = self:NewToken("item_" .. self:Lower(action))
    local payload
    if action == "EQUIP" then
        payload = table.concat({ "ITEM_EQUIP", bot.name, token, bag, slot, itemId, count }, "~")
    elseif action == "USE" then
        payload = table.concat({ "ITEM_USE", bot.name, token, bag, slot, itemId, count }, "~")
    elseif action == "SELL" then
        payload = table.concat({ "ITEM_SELL", bot.name, token, bag, slot, itemId, count }, "~")
    elseif action == "DESTROY" then
        payload = table.concat({ "ITEM_DESTROY", bot.name, token, bag, slot, itemId, count }, "~")
    elseif action == "GIVE" then
        payload = table.concat({ "ITEM_TRADE", bot.name, token, bag, slot, itemId, count }, "~")
    else
        return false, "UNSUPPORTED_ITEM_ACTION"
    end

    tx.transportRoute = "BRIDGE_NATIVE"
    tx.bridgeToken = token
    tx.physicalSource = self:Copy(source)
    tx.sentAt = self:Now()
    tx.expiresAt = tx.sentAt + actionAckTimeout(self, tx)
    self.bridge.actionTokens[token] = tx.id
    self:SetTransactionState(tx, "SENT")
    local ok, err = self:BridgeSend("RUN", payload)
    if not ok then
        self.bridge.actionTokens[token] = nil
        self:SetTransactionState(tx, "FAILED", { error = err or "SEND_FAILED", completedAt = self:Now() })
        if type(tx.callback) == "function" then self:SafeCall(tx.callback, self:TransactionSnapshot(tx)) end
        return false, err
    end
    return true, token
end

function MB:BeginNativeItemAction(tx)
    local bot = tx and tx.targets and tx.targets[1] or nil
    if not tx or not bot then return false, "BOT_REQUIRED" end
    local descriptor = self.actions[tx.actionId]
    local action = self:Upper(descriptor and descriptor.semanticKind)
    tx.itemAction = action
    tx.itemId = tonumber(tx.args and tx.args.itemId)
    tx.transportRoute = "BRIDGE_NATIVE"
    if not tx.itemId or tx.itemId <= 0 then return false, "ITEM_ID_REQUIRED" end

    local txId, epoch = tx.id, tx.sessionEpoch
    local readId, readErr = self:RefreshDomain("BOT.INVENTORY_EXACT", bot.name, function(snapshot, meta)
        local current = MB.transactions and MB.transactions[txId] or nil
        if not current or current.sessionEpoch ~= epoch or current.state ~= "DISPATCHING" then return end
        if not snapshot then
            failAsyncItemDispatch(MB, current, (meta and (meta.error or meta.status)) or "EXACT_INVENTORY_REQUIRED")
            return
        end
        local source, sourceErr = MB:ResolveExactInventoryStack(bot.name, current.itemId, current.args and current.args.sourceBag, current.args and current.args.sourceSlot)
        if not source then
            failAsyncItemDispatch(MB, current, sourceErr or "ITEM_NOT_FOUND_EXACT")
            return
        end
        if action == "GIVE" then
            local ok, err = MB:BeginNativeTradeGive(current, bot, source)
            if not ok then failAsyncItemDispatch(MB, current, err or "TRADE_NOT_OPEN") end
            return
        end
        local ok, err = MB:DispatchNativeItemMutation(current, bot, source)
        if not ok and current.state == "DISPATCHING" then failAsyncItemDispatch(MB, current, err) end
    end, { timeout = 5 })
    if not readId then return false, readErr or "EXACT_INVENTORY_REQUIRED" end
    tx.exactInventoryReadId = readId
    return true
end

function MB:BeginExactDepositAction(tx)
    local bot = tx and tx.targets and tx.targets[1] or nil
    if not tx or not bot then return false, "BOT_REQUIRED" end
    local action = self:Upper(tx.args and tx.args.action)
    local itemId = tonumber(tx.args and tx.args.itemId) or 0
    if (action ~= "BANK_DEPOSIT" and action ~= "GBANK_DEPOSIT") or itemId <= 0 then return false, "INVALID_EXACT_DEPOSIT_ACTION" end
    if not self:BridgeHasCapability("INVENTORY_EXACT_V1") or not self:BridgeHasCapability("ITEM_DEPOSIT_EXACT_V1") then return false, "CAPABILITY_UNAVAILABLE" end
    tx.itemAction = action
    tx.itemId = itemId
    tx.transportRoute = "BRIDGE_EXACT"
    local txId, epoch = tx.id, tx.sessionEpoch
    local readId, readErr = self:RefreshDomain("BOT.INVENTORY_EXACT", bot.name, function(snapshot, meta)
        local current = MB.transactions and MB.transactions[txId] or nil
        if not current or current.sessionEpoch ~= epoch or current.state ~= "DISPATCHING" then return end
        if not snapshot then
            failAsyncItemDispatch(MB, current, (meta and (meta.error or meta.status)) or "EXACT_INVENTORY_REQUIRED")
            return
        end
        local source, sourceErr = MB:ResolveExactInventoryStack(bot.name, current.itemId, current.args and current.args.sourceBag, current.args and current.args.sourceSlot)
        if not source then failAsyncItemDispatch(MB, current, sourceErr or "ITEM_NOT_FOUND_EXACT"); return end
        local count = tonumber(source.count) or 0
        if count <= 0 or count > 1000 then failAsyncItemDispatch(MB, current, "SOURCE_COUNT_UNSUPPORTED"); return end
        current.physicalSource = MB:Copy(source)
        local ok, err = sendRun(MB, current, "ITEM_DEPOSIT_EXACT", function(token)
            return table.concat({ "ITEM_DEPOSIT_EXACT", bot.name, token, action, source.bag, source.slot, source.itemId, source.count }, "~")
        end)
        if not ok and current.state == "DISPATCHING" then failAsyncItemDispatch(MB, current, err or "SEND_FAILED") end
    end, { timeout = 5 })
    if not readId then return false, readErr or "EXACT_INVENTORY_REQUIRED" end
    tx.exactInventoryReadId = readId
    return true
end

function MB:BeginExactInventoryMove(tx)
    local bot = tx and tx.targets and tx.targets[1] or nil
    if not tx or not bot then return false, "BOT_REQUIRED" end
    if not self:BridgeHasCapability("INVENTORY_EXACT_V1") or not self:BridgeHasCapability("ITEM_MOVE_V1") then return false, "CAPABILITY_UNAVAILABLE" end
    tx.transportRoute = "BRIDGE_NATIVE"
    local txId, epoch = tx.id, tx.sessionEpoch
    local readId, readErr = self:RefreshDomain("BOT.INVENTORY_EXACT", bot.name, function(snapshot, meta)
        local current = MB.transactions and MB.transactions[txId] or nil
        if not current or current.sessionEpoch ~= epoch or current.state ~= "DISPATCHING" then return end
        if not snapshot then failAsyncItemDispatch(MB, current, (meta and (meta.error or meta.status)) or "EXACT_INVENTORY_REQUIRED"); return end
        local args = current.args or {}
        local view = MB:GetInventoryExactView(bot.name)
        if not view then failAsyncItemDispatch(MB, current, "EXACT_INVENTORY_REQUIRED"); return end
        local skey = tostring(args.srcBag) .. ":" .. tostring(args.srcSlot)
        local dkey = tostring(args.dstBag) .. ":" .. tostring(args.dstSlot)
        local source = view.itemsByPosition and view.itemsByPosition[skey] or nil
        local destination = view.itemsByPosition and view.itemsByPosition[dkey] or nil
        if not source then failAsyncItemDispatch(MB, current, "SOURCE_ITEM_NOT_FOUND"); return end
        if tonumber(source.itemId) ~= tonumber(args.srcItemId) or tonumber(source.count) ~= tonumber(args.srcCount) then failAsyncItemDispatch(MB, current, "SOURCE_STALE"); return end
        local dstItemId, dstCount = destination and tonumber(destination.itemId) or 0, destination and tonumber(destination.count) or 0
        if dstItemId ~= tonumber(args.dstItemId) or dstCount ~= tonumber(args.dstCount) then failAsyncItemDispatch(MB, current, "DESTINATION_STALE"); return end
        local valid, posErr = MB:IsExactInventoryPositionValid(bot.name, args.dstBag, args.dstSlot)
        if not valid then failAsyncItemDispatch(MB, current, posErr or "INVALID_DESTINATION_POSITION"); return end
        current.physicalSource = MB:Copy(source)
        current.physicalDestination = destination and MB:Copy(destination) or { bag = tonumber(args.dstBag), slot = tonumber(args.dstSlot), itemId = 0, count = 0, empty = true }
        local ok, err = sendRun(MB, current, "ITEM_MOVE", function(token)
            return table.concat({ "ITEM_MOVE", bot.name, token, source.bag, source.slot, source.itemId, source.count, args.dstBag, args.dstSlot, dstItemId, dstCount }, "~")
        end)
        if not ok and current.state == "DISPATCHING" then failAsyncItemDispatch(MB, current, err or "SEND_FAILED") end
    end, { timeout = 5 })
    if not readId then return false, readErr or "EXACT_INVENTORY_REQUIRED" end
    tx.exactInventoryReadId = readId
    return true
end

MB.tradeGive = MB.tradeGive or { pending = nil, active = {} }

function MB:IsTradeFrameOpen()
    return type(TradeFrame) == "table" and type(TradeFrame.IsShown) == "function" and (TradeFrame:IsShown() == true or TradeFrame:IsShown() == 1)
end

local function basePlayerName(value)
    value = tostring(value or "")
    return string.match(value, "^[^-]+") or value
end

function MB:GetObservedTradeRecipient()
    if type(UnitName) == "function" then
        local name = UnitName("NPC")
        if type(name) == "string" and self:Trim(name) ~= "" then return name end
    end
    if TradeFrameRecipientNameText and type(TradeFrameRecipientNameText.GetText) == "function" then
        local text = TradeFrameRecipientNameText:GetText()
        if type(text) == "string" and self:Trim(text) ~= "" then return text end
    end
    return nil
end

function MB:TradeRecipientMatches(bot)
    if not bot then return false end
    local observed = self:GetObservedTradeRecipient()
    if not observed then return true end -- legacy client may expose no reliable trade unit
    return self:Lower(basePlayerName(observed)) == self:Lower(basePlayerName(bot.name))
end

local function finishTradeGiveFailure(self, pending, reason)
    if not pending then return end
    local tx = self.transactions and self.transactions[pending.txId] or nil
    if self.tradeGive and self.tradeGive.pending == pending then self.tradeGive.pending = nil end
    if self.ClearWhisperPresentationSuppression then
        self:ClearWhisperPresentationSuppression("TRADE_INVENTORY_DUMP", pending.botKey, reason or "TRADE_GIVE_FAILED")
    end
    if tx and tx.state == "DISPATCHING" then
        tx.completedAt = self:Now()
        self.runtime.counters.actionsCompleted = self.runtime.counters.actionsCompleted + 1
        self:SetTransactionState(tx, "FAILED", { error = reason or "TRADE_NOT_OPEN" })
        if type(tx.callback) == "function" then self:SafeCall(tx.callback, self:TransactionSnapshot(tx)) end
    end
end

function MB:DispatchTradeGive(pending)
    if type(pending) ~= "table" then return false, "INVALID_ARGUMENT" end
    local tx = self.transactions and self.transactions[pending.txId] or nil
    local bot = pending.botKey and self.botRegistry[pending.botKey] or nil
    if not tx or tx.sessionEpoch ~= self.sessionEpoch or tx.state ~= "DISPATCHING" then return false, "CANCELLED" end
    if not bot then return false, "BOT_NOT_FOUND" end
    if not self:IsTradeFrameOpen() then return false, "TRADE_NOT_OPEN" end
    if not self:TradeRecipientMatches(bot) then return false, "TRADE_WRONG_RECIPIENT" end

    if self.tradeGive and self.tradeGive.pending == pending then self.tradeGive.pending = nil end
    self.tradeGive.active = self.tradeGive.active or {}
    self.tradeGive.active[tx.id] = { botKey = bot.key, botName = bot.name, epoch = self.sessionEpoch }
    tx.trade = { state = "OPEN", bot = bot.name, itemLinkSource = pending.itemLinkSource, native = pending.native == true }
    if pending.native == true then
        return self:DispatchNativeItemMutation(tx, bot, pending.physicalSource)
    end
    tx.itemLink = pending.itemLink
    tx.itemLinkSource = pending.itemLinkSource
    return sendChatAction(self, tx, { { route = "BOT", bot = bot.name, command = "give " .. tostring(pending.itemLink) } }, nil, function()
        return MB:IsTradeFrameOpen() and MB:TradeRecipientMatches(bot)
    end)
end

function MB:BeginTradeGive(tx, bot, itemLink, itemLinkSource)
    if not tx or not bot or self:Trim(itemLink) == "" then return false, "INVALID_ARGUMENT" end
    if type(InitiateTrade) ~= "function" then return false, "TRADE_API_UNAVAILABLE" end
    self.tradeGive = self.tradeGive or { pending = nil, active = {} }
    if self.tradeGive.pending then return false, "TRADE_BUSY" end

    local pending = { txId = tx.id, botKey = bot.key, itemLink = itemLink, itemLinkSource = itemLinkSource, epoch = self.sessionEpoch }
    if self:IsTradeFrameOpen() then
        if not self:TradeRecipientMatches(bot) then return false, "TRADE_WRONG_RECIPIENT" end
        return self:DispatchTradeGive(pending)
    end

    self.tradeGive.pending = pending
    tx.trade = { state = "OPENING", bot = bot.name, itemLinkSource = itemLinkSource }
    if self.SuppressNextTradeInventoryDump then self:SuppressNextTradeInventoryDump(bot.name) end
    local ok = pcall(InitiateTrade, bot.name)
    if not ok then
        self.tradeGive.pending = nil
        if self.ClearWhisperPresentationSuppression then self:ClearWhisperPresentationSuppression("TRADE_INVENTORY_DUMP", bot.name, "TRADE_API_FAILURE") end
        return false, "TRADE_API_UNAVAILABLE"
    end

    local expectedTxId, expectedEpoch = tx.id, self.sessionEpoch
    self:After(5.0, function()
        local current = MB.tradeGive and MB.tradeGive.pending or nil
        if current and current.txId == expectedTxId and current.epoch == expectedEpoch then
            finishTradeGiveFailure(MB, current, "TRADE_NOT_OPEN")
        end
    end)
    return true
end

function MB:BeginNativeTradeGive(tx, bot, physicalSource)
    if not tx or not bot or type(physicalSource) ~= "table" then return false, "INVALID_ARGUMENT" end
    if type(InitiateTrade) ~= "function" then return false, "TRADE_API_UNAVAILABLE" end
    self.tradeGive = self.tradeGive or { pending = nil, active = {} }
    if self.tradeGive.pending then return false, "TRADE_BUSY" end

    local pending = { txId = tx.id, botKey = bot.key, physicalSource = self:Copy(physicalSource), native = true, epoch = self.sessionEpoch }
    if self:IsTradeFrameOpen() then
        if not self:TradeRecipientMatches(bot) then return false, "TRADE_WRONG_RECIPIENT" end
        return self:DispatchTradeGive(pending)
    end

    self.tradeGive.pending = pending
    tx.trade = { state = "OPENING", bot = bot.name, native = true }
    if self.SuppressNextTradeInventoryDump then self:SuppressNextTradeInventoryDump(bot.name) end
    local ok = pcall(InitiateTrade, bot.name)
    if not ok then
        self.tradeGive.pending = nil
        if self.ClearWhisperPresentationSuppression then self:ClearWhisperPresentationSuppression("TRADE_INVENTORY_DUMP", bot.name, "TRADE_API_FAILURE") end
        return false, "TRADE_API_UNAVAILABLE"
    end
    local expectedTxId, expectedEpoch = tx.id, self.sessionEpoch
    self:After(5.0, function()
        local current = MB.tradeGive and MB.tradeGive.pending or nil
        if current and current.txId == expectedTxId and current.epoch == expectedEpoch then
            finishTradeGiveFailure(MB, current, "TRADE_NOT_OPEN")
        end
    end)
    return true
end

function MB:HandleTradeShow()
    local pending = self.tradeGive and self.tradeGive.pending or nil
    if not pending then return end
    local ok, err = self:DispatchTradeGive(pending)
    if not ok then finishTradeGiveFailure(self, pending, err or "TRADE_NOT_OPEN") end
end

function MB:HandleTradeClosed()
    local state = self.tradeGive
    if self.ClearWhisperPresentationSuppression then self:ClearWhisperPresentationSuppression("TRADE_INVENTORY_DUMP", nil, "TRADE_CLOSED") end
    if not state then return end
    if state.pending then finishTradeGiveFailure(self, state.pending, "TRADE_CLOSED") end

    local refresh = {}
    for txId, active in pairs(state.active or {}) do
        if active and active.epoch == self.sessionEpoch and active.botKey then refresh[active.botKey] = active.botName or active.botKey end
        state.active[txId] = nil
    end
    for botKey, botRef in pairs(refresh) do
        local targetRef = botRef
        self:InvalidateBotDomain("BOT.INVENTORY", botKey, "TRADE_CLOSED")
        if self:BridgeHasCapability("INVENTORY_EXACT_V1") then self:InvalidateBotDomain("BOT.INVENTORY_EXACT", botKey, "TRADE_CLOSED") end
        self:After(0.25, function()
            MB:RefreshDomain("BOT.INVENTORY", targetRef)
            if MB:BridgeHasCapability("INVENTORY_EXACT_V1") then MB:RefreshDomain("BOT.INVENTORY_EXACT", targetRef) end
        end)
        self:After(1.00, function()
            MB:RefreshDomain("BOT.INVENTORY", targetRef)
            if MB:BridgeHasCapability("INVENTORY_EXACT_V1") then MB:RefreshDomain("BOT.INVENTORY_EXACT", targetRef) end
        end)
    end
end

local function failTalentSpecDispatch(self, tx, reason)
    if not tx or tx.state ~= "DISPATCHING" then return end
    tx.completedAt = self:Now()
    self.runtime.counters.actionsCompleted = self.runtime.counters.actionsCompleted + 1
    self:SetTransactionState(tx, "FAILED", { error = reason or "TALENT_SPEC_PREFLIGHT_FAILED" })
    if type(tx.callback) == "function" then self:SafeCall(tx.callback, self:TransactionSnapshot(tx)) end
end

function MB:BeginTalentSpecApply(tx)
    if not tx or tx.state ~= "DISPATCHING" then return false, "INVALID_TRANSACTION" end
    local bot = tx.resolvedTargets and tx.resolvedTargets[1] or nil
    if not bot then return false, "BOT_REQUIRED" end
    local live = self:ResolveBot(bot.name)
    if not live or live.online ~= true then return false, "BOT_OFFLINE" end

    local requestedSpecIndex = tonumber(tx.args and tx.args.specIndex)
    local requestedSlot = normalizeTalentSlot(self, tx.args and tx.args.slot)
    if requestedSpecIndex == nil or requestedSpecIndex < 0 or requestedSpecIndex > 30 or math.floor(requestedSpecIndex) ~= requestedSpecIndex then
        return false, "INVALID_SPEC_INDEX"
    end
    if requestedSlot == nil then return false, "INVALID_TALENT_SLOT" end

    local readId, readErr = self:RefreshDomain("BOT.TALENT_SPECS", bot.name, function(snapshot, meta)
        if tx.sessionEpoch ~= MB.sessionEpoch or tx.state ~= "DISPATCHING" then return end
        if not snapshot then
            failTalentSpecDispatch(MB, tx, meta and (meta.error or meta.status) or "TALENT_SPECS_REFRESH_FAILED")
            return
        end

        local selected = findTalentSpec(snapshot, requestedSpecIndex)
        if not selected then failTalentSpecDispatch(MB, tx, "SPEC_NOT_AVAILABLE"); return end

        local resolvedSlot = requestedSlot
        if resolvedSlot == "CURRENT" then
            resolvedSlot = snapshot.current and tonumber(snapshot.current.slot) or nil
            if resolvedSlot ~= 1 and resolvedSlot ~= 2 then
                failTalentSpecDispatch(MB, tx, "CURRENT_SLOT_UNAVAILABLE")
                return
            end
        end

        local currentBot = MB:ResolveBot(bot.name)
        if not currentBot or currentBot.online ~= true then failTalentSpecDispatch(MB, tx, "BOT_OFFLINE"); return end

        tx.args.slot = resolvedSlot
        tx.args.specIndex = requestedSpecIndex
        tx.talentSpec = MB:Copy(selected)
        tx.talentSpecPreflight = {
            readId = tx.talentSpecPreflightReadId,
            source = meta and meta.source or nil,
            current = snapshot.current and MB:Copy(snapshot.current) or nil,
        }
        return sendRun(MB, tx, "TALENT_SPEC_APPLY", function(token)
            -- Current bridge contract is token, encoded bot, slot, premade spec index.
            return table.concat({ "TALENT_SPEC_APPLY", token, MB:EncodeField(bot.name), resolvedSlot, requestedSpecIndex }, "~")
        end)
    end)
    tx.talentSpecPreflightReadId = readId
    if not readId then
        if tx.state == "DISPATCHING" then failTalentSpecDispatch(self, tx, readErr or "TALENT_SPECS_REFRESH_FAILED") end
        return tx.state ~= "FAILED", readErr
    end
    return true, readId
end


local function rtscBotSetKey(bot)
    if type(bot) ~= "table" then return nil end
    return bot.key or (bot.name and string.lower(bot.name)) or nil
end

local function sameRTSCBotSet(left, right)
    if type(left) ~= "table" or type(right) ~= "table" or #left ~= #right then return false end
    local set = {}
    for _, bot in ipairs(left) do
        local key = rtscBotSetKey(bot)
        if not key then return false end
        set[key] = true
    end
    for _, bot in ipairs(right) do
        local key = rtscBotSetKey(bot)
        if not key or not set[key] then return false end
    end
    return true
end

local function exactNativeGroupPrefix(self, targets)
    local candidates = {
        { selector = "rangeddps", prefix = "@rangeddps" },
        { selector = "meleedps", prefix = "@meleedps" },
        { selector = "tank", prefix = "@tank" },
        { selector = "healer", prefix = "@heal" },
        { selector = "dps", prefix = "@dps" },
        { selector = "ranged", prefix = "@ranged" },
    }

    for group = 1, 8 do
        candidates[#candidates + 1] = { selector = "group:" .. tostring(group), prefix = "@group" .. tostring(group) }
    end

    for _, candidate in ipairs(candidates) do
        local bots = self:SelectBots(candidate.selector)
        if bots and sameRTSCBotSet(targets, bots) then
            return candidate.prefix, candidate.selector
        end
    end

    local all = self:SelectBots("all")
    if all and sameRTSCBotSet(targets, all) then
        return "", "all"
    end

    return nil
end

local function exactRTSCGroupCommand(self, targets, slot)
    local prefix, selector = exactNativeGroupPrefix(self, targets)
    if prefix == nil then return nil end
    local command = "rtsc go " .. tostring(slot)
    if prefix ~= "" then command = prefix .. " " .. command end
    return command, selector
end

function MB:DispatchAction(tx)
    local descriptor = self.actions[tx.actionId]
    local args = tx.args or {}
    local defaultScope = descriptor.defaultScope or (descriptor.family == "FORMATION" and "GROUP" or "BOT")
    local scope = self:NormalizeScope(args.scope, defaultScope)
    local target = self:Trim(args.target)
    tx.targets = self:Copy(tx.resolvedTargets or {})
    if scope == "BOT" then
        if #tx.targets ~= 1 then return false, "BOT_REQUIRED" end
        target = tx.targets[1].name
    elseif descriptor.family == "STRATEGY" then
        target = ""
    end
    tx.scope = scope

    if descriptor.family == "BOT_LIFECYCLE" then
        if #tx.targets ~= 1 then return false, "BOT_REQUIRED" end
        if not self.BeginBotLifecycle then return false, "LIFECYCLE_SERVICE_UNAVAILABLE" end
        return self:BeginBotLifecycle(tx)
    end

    if descriptor.family == "TALENT_SPEC_APPLY" then
        if #tx.targets ~= 1 then return false, "BOT_REQUIRED" end
        return self:BeginTalentSpecApply(tx)
    end

    if descriptor.family == "ITEM_SEMANTIC" then
        if #tx.targets ~= 1 then return false, "BOT_REQUIRED" end
        local selectedRoute = self:Upper(args.selectedRoute)
        tx.itemAction = self:Upper(descriptor.semanticKind)
        tx.itemId = tonumber(args.itemId)
        tx.itemLink = self:Trim(args.itemLink)
        tx.itemLinkSource = self:Trim(args.itemLinkSource)
        tx.clientLink = self:Trim(args.clientLink)
        tx.serverLink = self:Trim(args.serverLink)
        tx.transportRoute = selectedRoute
        if selectedRoute == "BRIDGE_NATIVE" then
            return self:BeginNativeItemAction(tx)
        elseif selectedRoute == "CHAT" then
            local commandByKind = { EQUIP = "e", USE = "u", SELL = "s", DESTROY = "destroy", GIVE = "give" }
            local prefix = commandByKind[tx.itemAction]
            if not prefix or tx.itemLink == "" then return false, "INVALID_ITEM_CHAT_ACTION" end
            if tx.itemAction == "GIVE" then
                return self:BeginTradeGive(tx, tx.targets[1], tx.itemLink, tx.itemLinkSource)
            end
            return sendChatAction(self, tx, { { route = "BOT", bot = tx.targets[1].name, command = prefix .. " " .. tx.itemLink } })
        end
        return false, "INVALID_ITEM_ROUTE"
    end

    if descriptor.family == "ITEM_MOVE" then
        if #tx.targets ~= 1 then return false, "BOT_REQUIRED" end
        return self:BeginExactInventoryMove(tx)
    elseif descriptor.family == "ITEM_UNEQUIP" then
        if #tx.targets ~= 1 then return false, "BOT_REQUIRED" end
        tx.itemAction = "UNEQUIP"
        tx.transportRoute = "BRIDGE_NATIVE"
        return sendRun(self, tx, "ITEM_UNEQUIP", function(token)
            return table.concat({ "ITEM_UNEQUIP", tx.targets[1].name, token, args.equipmentSlot, args.itemId }, "~")
        end)
    end

    if descriptor.family == "SPELL_EXCLUSION_SET" then
        if #tx.targets ~= 1 then return false, "BOT_REQUIRED" end
        local bot = tx.targets[1]
        local spellId = tonumber(args.spellId)
        local enabled = args.enabled == true
        local command = "ss " .. (enabled and "-" or "+") .. tostring(spellId)
        return sendChatAction(self, tx, { { route = "BOT", bot = bot.name, command = command } }, nil, function()
            local live = MB:ResolveBot(bot.name)
            return live and live.online == true
        end)
    elseif descriptor.family == "SPELL_CAST" then
        if #tx.targets ~= 1 then return false, "BOT_REQUIRED" end
        local bot = tx.targets[1]
        local spellId = tonumber(args.spellId)
        -- Numeric IDs are accepted by the current Playerbots CastCustomSpellAction.
        return sendChatAction(self, tx, { { route = "BOT", bot = bot.name, command = "cast " .. tostring(spellId) } }, nil, function()
            local live = MB:ResolveBot(bot.name)
            return live and live.online == true
        end)
    end

    if descriptor.route == "CHAT" then
        local sequence = {}
        if descriptor.family == "RTSC_ENABLE" then
            sequence[1] = { route = "GROUP", command = "rtsc" }
            return sendChatAction(self, tx, sequence)
        elseif descriptor.family == "RTSC_PREPARE" or descriptor.family == "RTSC_SELECT" then
            -- Bare `rtsc` enables RTSC/AEDM. `rtsc cancel` disables it, so it must
            -- never be used as PREPARE/SELECT initialization. This keeps the
            -- secure AEDM click usable after Core preparation.
            sequence[#sequence + 1] = { route = "GROUP", command = "rtsc" }
            for _, bot in ipairs(tx.targets or {}) do sequence[#sequence + 1] = { route = "BOT", bot = bot.name, command = "rtsc select" } end
            local slot = tonumber(args.slot) or 0
            if descriptor.family == "RTSC_PREPARE" and slot > 0 then sequence[#sequence + 1] = { route = "GROUP", command = "rtsc save " .. tostring(slot) } end
            local placement = descriptor.family == "RTSC_PREPARE" and {
                status = "PREPARED", slot = slot > 0 and slot or nil, targets = self:Copy(tx.targets or {}), targetInfo = self:Copy(tx.targetInfo), contract = self:GetRTSCPlacementContract(),
            } or nil
            return sendChatAction(self, tx, sequence, placement)
        elseif descriptor.family == "RTSC_GO" then
            local groupCommand, matchedSelector = exactRTSCGroupCommand(self, tx.targets or {}, args.slot)
            if groupCommand then
                tx.rtscDispatchMode = "GROUPCALL"
                tx.rtscMatchedSelector = matchedSelector
                sequence[1] = { route = "GROUP", command = groupCommand }
                return sendChatAction(self, tx, sequence)
            end

            tx.rtscDispatchMode = "EXACT_BOT_BURST"
            for _, bot in ipairs(tx.targets or {}) do
                sequence[#sequence + 1] = { route = "BOT", bot = bot.name, command = "rtsc go " .. tostring(args.slot) }
            end
            -- Movement orders are latency-sensitive. Keep exact frozen-set
            -- semantics but use the minimum safe chat spacing instead of the
            -- general-purpose 250 ms Core chat cadence.
            return sendChatAction(self, tx, sequence, nil, nil, 0.05)
        elseif descriptor.family == "RTSC_SAVE" then
            sequence[1] = { route = "GROUP", command = "rtsc save " .. tostring(args.slot) }
            return sendChatAction(self, tx, sequence, { status = "SAVE_ARMED", slot = tonumber(args.slot), targets = {}, targetInfo = self:Copy(tx.targetInfo), contract = self:GetRTSCPlacementContract() })
        elseif descriptor.family == "RTSC_UNSAVE" then
            sequence[1] = { route = "GROUP", command = "rtsc unsave " .. tostring(args.slot) }
            return sendChatAction(self, tx, sequence)
        elseif descriptor.family == "RTSC_CANCEL" then
            sequence[1] = { route = "GROUP", command = "rtsc cancel" }
            return sendChatAction(self, tx, sequence)
        elseif descriptor.family == "TACTICAL_ORDER" then
            local command = self:Trim(args.command)
            if command == "" then return false, "COMMAND_REQUIRED" end

            local prefix, matchedSelector = exactNativeGroupPrefix(self, tx.targets or {})
            if prefix ~= nil and self:ChatGroupChannel() then
                tx.tacticalOrderDispatchMode = "GROUPCALL"
                tx.tacticalOrderMatchedSelector = matchedSelector
                if prefix ~= "" then command = prefix .. " " .. command end
                sequence[1] = { route = "GROUP", command = command }
                return sendChatAction(self, tx, sequence)
            end

            tx.tacticalOrderDispatchMode = "EXACT_BOT_BURST"
            for _, bot in ipairs(tx.targets or {}) do
                sequence[#sequence + 1] = { route = "BOT", bot = bot.name, command = command }
            end
            return sendChatAction(self, tx, sequence, nil, nil, 0.05)
        elseif descriptor.family == "QUEST_NPC" then
            if #tx.targets ~= 1 then return false, "BOT_REQUIRED" end
            local bot = tx.targets[1]
            local targetGuid = args.targetGuid
            local command = descriptor.semanticKind == "TALK_TARGET" and "talk" or "accept *"
            return sendChatAction(self, tx, { { route = "BOT", bot = bot.name, command = command } }, nil, function()
                local online = MB:ResolveBot(bot.name)
                return online and online.online == true
                    and type(UnitGUID) == "function" and UnitGUID("target") == targetGuid
                    and not (type(UnitIsPlayer) == "function" and UnitIsPlayer("target"))
                    and not (type(UnitCanAttack) == "function" and UnitCanAttack("player", "target"))
            end)
        elseif descriptor.family == "QUEST_ABANDON" then
            if #tx.targets ~= 1 then return false, "BOT_REQUIRED" end
            if not self.BeginQuestAbandon then return false, "QUEST_SERVICE_UNAVAILABLE" end
            return self:BeginQuestAbandon(tx)
        elseif descriptor.family == "QUEST_ACCEPT_LINK" then
            if #tx.targets == 0 then return false, "NO_TARGETS" end
            if not self.BeginQuestAcceptLink then return false, "QUEST_SERVICE_UNAVAILABLE" end
            return self:BeginQuestAcceptLink(tx)
        elseif descriptor.family == "ITEM_CHAT" then
            if #tx.targets ~= 1 then return false, "BOT_REQUIRED" end
            local commandByKind = { EQUIP = "e", USE = "u", SELL = "s", DESTROY = "destroy", GIVE = "give" }
            local prefix = commandByKind[descriptor.semanticKind]
            local itemLink = self:Trim(args.itemLink ~= nil and args.itemLink or (self:Trim(args.clientLink) ~= "" and args.clientLink or args.serverLink))
            if not prefix or itemLink == "" then return false, "INVALID_ITEM_CHAT_ACTION" end
            tx.itemAction = descriptor.semanticKind
            tx.itemId = tonumber(args.itemId)
            tx.itemLink = itemLink
            tx.itemLinkSource = self:Trim(args.itemLinkSource)
            tx.clientLink = self:Trim(args.clientLink)
            tx.serverLink = self:Trim(args.serverLink)
            if descriptor.semanticKind == "GIVE" then
                return self:BeginTradeGive(tx, tx.targets[1], itemLink, tx.itemLinkSource)
            end
            sequence[1] = { route = "BOT", bot = tx.targets[1].name, command = prefix .. " " .. itemLink }
            return sendChatAction(self, tx, sequence)
        end
        return false, "CHAT_ACTION_NOT_IMPLEMENTED"
    end

    if descriptor.family == "RTI" or descriptor.family == "COMBAT" or descriptor.family == "LOOT" or descriptor.family == "POSITION" then
        local command = self:Trim(args.command)
        if command == "" then return false, "COMMAND_REQUIRED" end
        return sendRun(self, tx, descriptor.family, function(token)
            return descriptor.family .. "~" .. scope .. "~" .. self:EncodeField(target) .. "~" .. token .. "~" .. self:EncodeField(command)
        end)
    elseif descriptor.family == "STRATEGY" then
        local stateScope = self:Upper(args.stateScope)
        local changes = validateStrategyChanges(self, args.changes)
        if stateScope ~= "C" and stateScope ~= "N" then return false, "STATE_SCOPE_REQUIRED" end
        if not changes then return false, "INVALID_CHANGES" end
        if scope == "BOT" and target == "" then return false, "BOT_REQUIRED" end
        if scope ~= "BOT" then target = "" end
        return sendRun(self, tx, "STRATEGY", function(token)
            return "STRATEGY~" .. scope .. "~" .. self:EncodeField(target) .. "~" .. token .. "~" .. stateScope .. "~" .. self:EncodeField(changes)
        end)
    elseif descriptor.family == "FORMATION" then
        local formation = self:Lower(args.formation)
        if scope ~= "GROUP" or not FORMATIONS[formation] then return false, "INVALID_FORMATION" end
        return sendRun(self, tx, "FORMATION", function(token)
            return "FORMATION~GROUP~~" .. token .. "~" .. self:EncodeField(formation)
        end)
    elseif descriptor.family == "OUTFIT" then
        local command = self:Trim(args.command)
        if command == "" then return false, "COMMAND_REQUIRED" end
        return sendRun(self, tx, "OUTFIT", function(token)
            return "OUTFIT~" .. target .. "~" .. token .. "~" .. self:EncodeField(command) .. "~" .. (args.persist and "1" or "0")
        end)
    elseif descriptor.family == "TRAINER_LEARN" then
        local trainerEntry = tonumber(args.trainerEntry) or 0
        local spellId = self:Upper(args.spellId)
        if spellId ~= "ALL" then
            local numeric = tonumber(args.spellId) or 0
            if numeric <= 0 then return false, "SPELL_REQUIRED" end
            spellId = tostring(numeric)
        end
        if trainerEntry <= 0 then return false, "TRAINER_REQUIRED" end
        return sendRun(self, tx, "TRAINER_LEARN", function(token)
            return "TRAINER_LEARN~" .. target .. "~" .. token .. "~" .. tostring(trainerEntry) .. "~" .. spellId
        end)
    elseif descriptor.family == "CRAFT_RECIPE" then
        local skillId, spellId, itemId = tonumber(args.skillId) or 0, tonumber(args.spellId) or 0, tonumber(args.itemId) or 0
        if skillId <= 0 or spellId <= 0 or itemId < 0 then return false, "INVALID_RECIPE" end
        return sendRun(self, tx, "CRAFT_RECIPE", function(token)
            return "CRAFT_RECIPE~" .. target .. "~" .. token .. "~" .. tostring(skillId) .. "~" .. tostring(spellId) .. "~" .. tostring(itemId)
        end)
    elseif descriptor.family == "ITEM_ACTION" then
        local action, itemId, count = self:Upper(args.action), tonumber(args.itemId) or 0, tonumber(args.count) or 0
        if not ITEM_ACTIONS[action] then return false, "UNSUPPORTED_ITEM_ACTION" end
        local zeroIdAction = ITEM_ACTION_ZERO_ID[action] == true
        if (zeroIdAction and (itemId ~= 0 or count ~= 0)) or (not zeroIdAction and itemId <= 0) or count < 0 then return false, "INVALID_ITEM_ACTION" end
        tx.itemAction = action
        tx.transportRoute = self:Upper(args.selectedRoute) ~= "" and self:Upper(args.selectedRoute) or "BRIDGE_GENERIC"
        if tx.transportRoute == "BRIDGE_EXACT" then
            return self:BeginExactDepositAction(tx)
        end
        return sendRun(self, tx, "ITEM_ACTION", function(token)
            return "ITEM_ACTION~" .. target .. "~" .. token .. "~" .. action .. "~" .. tostring(itemId) .. "~" .. tostring(count)
        end)
    elseif descriptor.family == "ITEM_BUYBACK" then
        local slot, itemId, count, price = tonumber(args.slot), tonumber(args.itemId), tonumber(args.count), tonumber(args.price)
        if not slot or slot < 74 or slot > 85 or not itemId or itemId <= 0 or not count or count <= 0 or not price or price < 0 then return false, "INVALID_BUYBACK" end
        return sendRun(self, tx, "BUYBACK", function(token)
            return "BUYBACK_ITEM~" .. target .. "~" .. token .. "~" .. tostring(slot) .. "~" .. tostring(itemId) .. "~" .. tostring(count) .. "~" .. tostring(price)
        end)
    end
    return false, "ACTION_NOT_IMPLEMENTED"
end

function MB:ExecuteAction(originModule, actionId, targetSpec, args, callback)
    originModule = self:Trim(originModule)
    if originModule == "" then return nil, "MODULE_REQUIRED" end
    if not self.modules[originModule] then self:RegisterModule(originModule) end
    local can, reason, availability = self:CanExecuteAction(actionId, targetSpec, args)
    if not can then return nil, reason end
    local tx = self:CreateTransaction(originModule, actionId, targetSpec, availability and availability.normalizedArgs or args, callback)
    tx.resolvedTargets = availability and self:Copy(availability.targets or {}) or {}
    tx.targetInfo = availability and self:Copy(availability.targetInfo) or nil
    self:SetTransactionState(tx, "DISPATCHING")
    local ok, err = self:DispatchAction(tx)
    if not ok and tx.state ~= "FAILED" then
        self:SetTransactionState(tx, "FAILED", { error = err, completedAt = self:Now() })
        if type(callback) == "function" then self:SafeCall(callback, self:Copy(tx)) end
        return tx.id, err
    end
    return tx.id
end

function MB:ExecuteActionSet(originModule, actionId, selector, args, callback)
    local snapshot = self:ResolveSelection(selector)
    if #snapshot == 0 then return nil, "NO_TARGETS" end
    local ids = {}
    for _, bot in ipairs(snapshot) do
        local perArgs = self:Copy(args or {})
        perArgs.scope = "BOT"
        local id, err = self:ExecuteAction(originModule, actionId, bot.name, perArgs, callback)
        ids[#ids + 1] = { bot = bot.name, transactionId = id, error = err }
    end
    return ids
end

function MB:InvalidateBotDomain(domainId, botKey, reason)
    local descriptor = self.dataDomains[domainId]
    if not descriptor then return end
    if descriptor.scope == "BOT" then
        self:InvalidateData(domainId, botKey, reason)
    elseif descriptor.scope == "BOT_VARIANT" then
        local prefix = botKey .. "|"
        for key, entry in pairs(self.cache) do
            if entry.meta and entry.meta.domain == domainId and string.sub(entry.meta.targetKey or "", 1, #prefix) == prefix then
                self:InvalidateData(domainId, entry.meta.targetKey, reason)
            end
        end
    end
end

function MB:ApplyActionInvalidation(tx, result)
    local descriptor = self.actions[tx.actionId]
    local reason = "ACTION:" .. tx.actionId
    if descriptor and descriptor.invalidates then
        for _, domainId in ipairs(descriptor.invalidates) do
            local domain = self.dataDomains[domainId]
            if domain and domain.scope == "GLOBAL" then self:InvalidateData(domainId, "GLOBAL", reason)
            else
                for _, bot in ipairs(tx.targets or {}) do
                    self:InvalidateBotDomain(domainId, bot.key, reason)
                    if domainId == "BOT.EQUIPMENT" and self.ScheduleEquipmentRefreshIfInterested then
                        self:ScheduleEquipmentRefreshIfInterested(bot.key, bot.name, 0.65)
                    end
                end
            end
        end
    end
    if tx.actionId == "ITEM.ACTION" then
        for _, bot in ipairs(tx.targets or {}) do
            if tx.itemAction == "BANK_DEPOSIT" or tx.itemAction == "BANK_WITHDRAW" then self:InvalidateBotDomain("BOT.BANK", bot.key, reason) end
            if tx.itemAction == "GBANK_DEPOSIT" or tx.itemAction == "GBANK_WITHDRAW" then self:InvalidateBotDomain("BOT.GUILD_BANK", bot.key, reason) end
            if tx.itemAction == "SELL_GREY" or tx.itemAction == "SELL_VENDOR" then self:InvalidateBotDomain("BOT.BUYBACK", bot.key, reason) end
        end
    end
end

local ACTION_ACK_BY_FAMILY = {
    RTI = "RTI_ACK",
    COMBAT = "COMBAT_ACK",
    STRATEGY = "STRATEGY_ACK",
    LOOT = "LOOT_ACK",
    POSITION = "POSITION_ACK",
    FORMATION = "FORMATION_ACK",
    OUTFIT = "OUTFITS_CMD",
    TRAINER_LEARN = "TRAINER_LEARN",
    TALENT_SPEC_APPLY = "TALENT_SPEC_APPLY_RESULT",
    CRAFT_RECIPE = "PROFESSION_RECIPE_CRAFT",
    ITEM_ACTION = "INVENTORY_ITEM_ACTION",
    ITEM_BUYBACK = "BUYBACK_RESULT",
}

local function sameText(self, a, b)
    return self:Lower(self:Trim(a)) == self:Lower(self:Trim(b))
end

function MB:ValidateBridgeActionResult(tx, result)
    if type(tx) ~= "table" or type(result) ~= "table" then return false, "INVALID_RESULT" end
    if tx.sessionEpoch ~= self.sessionEpoch then return false, "STALE_SESSION" end
    local descriptor = self.actions[tx.actionId]
    if not descriptor then return false, "UNKNOWN_ACTION" end

    local opcode = self:Upper(result.opcode)
    if opcode == "ERR" then return true end
    local expectedOpcode = ACTION_ACK_BY_FAMILY[descriptor.family]
    if descriptor.family == "ITEM_ACTION" and self:Upper(tx.transportRoute) == "BRIDGE_EXACT" then
        expectedOpcode = "ITEM_DEPOSIT_EXACT"
    elseif descriptor.family == "ITEM_MOVE" then
        expectedOpcode = "INVENTORY_ITEM_MOVE"
    elseif descriptor.family == "ITEM_UNEQUIP" then
        expectedOpcode = "INVENTORY_ITEM_UNEQUIP"
    elseif descriptor.family == "ITEM_SEMANTIC" then
        local expectedByAction = {
            EQUIP = "INVENTORY_ITEM_EQUIP", USE = "INVENTORY_ITEM_USE", SELL = "INVENTORY_ITEM_SELL",
            DESTROY = "INVENTORY_ITEM_DESTROY", GIVE = "INVENTORY_ITEM_TRADE",
        }
        expectedOpcode = expectedByAction[self:Upper(descriptor.semanticKind)]
    end
    if expectedOpcode and opcode ~= expectedOpcode then return false, "UNEXPECTED_OPCODE" end

    local scope = self:Upper(tx.scope)
    local targetName = tx.targets and tx.targets[1] and tx.targets[1].name or ""

    if descriptor.family == "STRATEGY" then
        if self:Upper(result.scope) ~= scope then return false, "SCOPE_MISMATCH" end
        local expectedTarget = scope == "BOT" and targetName or ""
        if not sameText(self, result.target, expectedTarget) then return false, "TARGET_MISMATCH" end
        if self:Upper(result.stateScope) ~= self:Upper(tx.args and tx.args.stateScope) then return false, "STATE_SCOPE_MISMATCH" end
        local matched, succeeded, failed = tonumber(result.matched), tonumber(result.succeeded), tonumber(result.failed)
        if not matched or not succeeded or not failed or matched < 0 or succeeded < 0 or failed < 0 or succeeded + failed > matched then
            return false, "INVALID_COUNTS"
        end
        if matched == 0 then result.status = "no_match"
        elseif succeeded == matched and failed == 0 then result.status = "ok"
        elseif succeeded > 0 then result.status = "partial"
        else result.status = "failed" end
        result.success = result.status == "ok"
    elseif descriptor.family == "FORMATION" then
        if self:Upper(result.scope) ~= "GROUP" or self:Trim(result.target) ~= "" then return false, "FORMATION_SCOPE_MISMATCH" end
        if not sameText(self, result.formation, tx.args and tx.args.formation) then return false, "FORMATION_MISMATCH" end
        local succeeded, failed = tonumber(result.succeeded), tonumber(result.failed)
        if not succeeded or not failed or succeeded < 0 or failed < 0 then return false, "INVALID_COUNTS" end
        result.success = succeeded > 0 and failed == 0
        result.status = result.success and "ok" or (succeeded > 0 and "partial" or "failed")
    elseif descriptor.family == "RTI" or descriptor.family == "COMBAT" or descriptor.family == "LOOT" or descriptor.family == "POSITION" then
        if self:Upper(result.scope) ~= scope then return false, "SCOPE_MISMATCH" end
        local expectedTarget = scope == "BOT" and targetName or self:Trim(tx.args and tx.args.target)
        if not sameText(self, result.target, expectedTarget) then return false, "TARGET_MISMATCH" end
        result.success = (tonumber(result.executed) or 0) > 0
    elseif descriptor.family == "OUTFIT" then
        if not sameText(self, result.botName, targetName) then return false, "TARGET_MISMATCH" end
    elseif descriptor.family == "TRAINER_LEARN" then
        if not sameText(self, result.botName, targetName) then return false, "TARGET_MISMATCH" end
        if tonumber(result.trainerEntry) ~= tonumber(tx.args and tx.args.trainerEntry) then return false, "TRAINER_MISMATCH" end
        local expectedSpell = self:Upper(tx.args and tx.args.spellId)
        if expectedSpell ~= "ALL" and tonumber(result.spellId) ~= tonumber(tx.args and tx.args.spellId) then return false, "SPELL_MISMATCH" end
    elseif descriptor.family == "TALENT_SPEC_APPLY" then
        if not sameText(self, result.botName, targetName) then return false, "TARGET_MISMATCH" end
        local status = self:Upper(result.status)
        if status ~= "OK" and status ~= "ERR" then return false, "INVALID_TALENT_STATUS" end
        if result.success ~= (status == "OK") then return false, "TALENT_STATUS_MISMATCH" end
        if tonumber(result.slot) ~= tonumber(tx.args and tx.args.slot) then return false, "TALENT_SLOT_MISMATCH" end
        if tonumber(result.specIndex) ~= tonumber(tx.args and tx.args.specIndex) then return false, "TALENT_SPEC_MISMATCH" end
        if type(result.treePoints) ~= "table" or #result.treePoints ~= 3 then return false, "INVALID_TALENT_POINTS" end
        for i = 1, 3 do
            local points = tonumber(result.treePoints[i])
            if points == nil or points < 0 or points > 255 or math.floor(points) ~= points then return false, "INVALID_TALENT_POINTS" end
            result.treePoints[i] = points
        end
        result.buildSummary = tostring(result.treePoints[1]) .. "-" .. tostring(result.treePoints[2]) .. "-" .. tostring(result.treePoints[3])
    elseif descriptor.family == "CRAFT_RECIPE" then
        if not sameText(self, result.botName, targetName) then return false, "TARGET_MISMATCH" end
        if tonumber(result.skillId) ~= tonumber(tx.args and tx.args.skillId)
            or tonumber(result.spellId) ~= tonumber(tx.args and tx.args.spellId)
            or tonumber(result.itemId) ~= tonumber(tx.args and tx.args.itemId) then
            return false, "RECIPE_MISMATCH"
        end
    elseif descriptor.family == "ITEM_ACTION" then
        if not sameText(self, result.botName, targetName) then return false, "TARGET_MISMATCH" end
        if self:Upper(result.action) ~= self:Upper(tx.args and tx.args.action) then return false, "ITEM_ACTION_MISMATCH" end
        if tonumber(result.itemId) ~= tonumber(tx.args and tx.args.itemId) then return false, "ITEM_MISMATCH" end
        if self:Upper(tx.transportRoute) == "BRIDGE_EXACT" then
            local status = self:Upper(result.status)
            if status ~= "OK" and status ~= "ERR" then return false, "INVALID_ITEM_STATUS" end
            if result.success ~= (status == "OK") then return false, "ITEM_STATUS_MISMATCH" end
            local source = tx.physicalSource or {}
            if tonumber(result.srcBag) ~= tonumber(source.bag) or tonumber(result.srcSlot) ~= tonumber(source.slot)
                or tonumber(result.srcCount) ~= tonumber(source.count) then return false, "SOURCE_POSITION_MISMATCH" end
            local moved = tonumber(result.movedCount) or 0
            if result.success == true and moved ~= tonumber(source.count) then return false, "MOVED_COUNT_INVALID" end
            if result.success ~= true and moved ~= 0 then return false, "MOVED_COUNT_INVALID" end
        end
    elseif descriptor.family == "ITEM_BUYBACK" then
        if not sameText(self, result.botName, targetName) then return false, "TARGET_MISMATCH" end
        local status = self:Upper(result.status)
        if status ~= "OK" and status ~= "ERR" then return false, "INVALID_BUYBACK_STATUS" end
        if result.success ~= (status == "OK") then return false, "BUYBACK_STATUS_MISMATCH" end
        local args = tx.args or {}
        if tonumber(result.slot) ~= tonumber(args.slot) or tonumber(result.itemId) ~= tonumber(args.itemId)
            or tonumber(result.count) ~= tonumber(args.count) or tonumber(result.price) ~= tonumber(args.price) then
            return false, "BUYBACK_RESPONSE_MISMATCH"
        end
    elseif descriptor.family == "ITEM_MOVE" then
        if not sameText(self, result.botName, targetName) then return false, "TARGET_MISMATCH" end
        local status = self:Upper(result.status)
        if status ~= "OK" and status ~= "ERR" then return false, "INVALID_ITEM_STATUS" end
        if result.success ~= (status == "OK") then return false, "ITEM_STATUS_MISMATCH" end
        local source, destination = tx.physicalSource or {}, tx.physicalDestination or {}
        if tonumber(result.srcBag) ~= tonumber(source.bag) or tonumber(result.srcSlot) ~= tonumber(source.slot)
            or tonumber(result.dstBag) ~= tonumber(destination.bag) or tonumber(result.dstSlot) ~= tonumber(destination.slot) then
            return false, "POSITION_MISMATCH"
        end
    elseif descriptor.family == "ITEM_UNEQUIP" then
        if not sameText(self, result.botName, targetName) then return false, "TARGET_MISMATCH" end
        local status = self:Upper(result.status)
        if status ~= "OK" and status ~= "ERR" then return false, "INVALID_ITEM_STATUS" end
        if result.success ~= (status == "OK") then return false, "ITEM_STATUS_MISMATCH" end
        if tonumber(result.srcSlot) ~= tonumber(tx.args and tx.args.equipmentSlot) or tonumber(result.itemId) ~= tonumber(tx.args and tx.args.itemId) then
            return false, "EQUIPMENT_SOURCE_MISMATCH"
        end
    elseif descriptor.family == "ITEM_SEMANTIC" then
        if not sameText(self, result.botName, targetName) then return false, "TARGET_MISMATCH" end
        local itemStatus = self:Upper(result.status)
        if itemStatus ~= "OK" and itemStatus ~= "ERR" then return false, "INVALID_ITEM_STATUS" end
        if result.success ~= (itemStatus == "OK") then return false, "ITEM_STATUS_MISMATCH" end
        local source = tx.physicalSource or {}
        if tonumber(result.srcBag) ~= tonumber(source.bag) or tonumber(result.srcSlot) ~= tonumber(source.slot) then return false, "SOURCE_POSITION_MISMATCH" end
        if result.itemId ~= nil and tonumber(result.itemId) ~= tonumber(source.itemId) then return false, "ITEM_MISMATCH" end
        if result.srcCount ~= nil and tonumber(result.srcCount) ~= tonumber(source.count) then return false, "SOURCE_COUNT_MISMATCH" end
        local action = self:Upper(descriptor.semanticKind)
        if action == "GIVE" and result.success == true then
            local tradeSlot = tonumber(result.tradeSlot)
            if tradeSlot == nil or tradeSlot < 0 or tradeSlot > 5 then return false, "TRADE_SLOT_INVALID" end
        elseif action == "SELL" then
            local sold = tonumber(result.soldCount) or 0
            if result.success == true and (sold < 1 or sold > (tonumber(source.count) or 0)) then return false, "SOLD_COUNT_INVALID" end
            if result.success ~= true and sold ~= 0 then return false, "SOLD_COUNT_INVALID" end
        elseif action == "EQUIP" and result.success == true then
            local dst = tonumber(result.dstSlot)
            if dst == nil or dst < 0 or dst > 255 then return false, "DESTINATION_SLOT_INVALID" end
        end
    end
    return true
end

function MB:HandleBridgeActionResult(token, result)
    token = self:Trim(token)
    local txId = self.bridge.actionTokens[token]
    local tx = txId and self.transactions[txId] or nil
    if not tx then return false end

    local valid, validationError = self:ValidateBridgeActionResult(tx, result or {})
    if not valid then
        self.bridge.lastError = "ACTION_ACK_REJECTED:" .. tostring(validationError or "INVALID")
        self:Log("WARN", "Rejected action ACK tx=%s token=%s reason=%s", tostring(tx.id), tostring(token), tostring(validationError))
        return false
    end

    self.bridge.actionTokens[token] = nil
    local descriptor = self.actions[tx.actionId] or {}
    tx.result = self:Copy(result or {})
    tx.completedAt = self:Now()
    self.runtime.counters.actionsCompleted = self.runtime.counters.actionsCompleted + 1
    if result and result.success == true then
        self:SetTransactionState(tx, "CONFIRMED")
        self:ApplyActionInvalidation(tx, result)
        if descriptor.family == "ITEM_SEMANTIC" or descriptor.family == "ITEM_MOVE" or descriptor.family == "ITEM_UNEQUIP" or descriptor.family == "ITEM_BUYBACK"
            or (descriptor.family == "ITEM_ACTION" and (self:Upper(tx.transportRoute) == "BRIDGE_EXACT" or tx.itemAction == "SELL_GREY" or tx.itemAction == "SELL_VENDOR")) then
            local bot = tx.targets and tx.targets[1]
            if bot then
                local botName = bot.name
                self:After(0.25, function()
                    MB:RefreshDomain("BOT.INVENTORY", botName)
                    if MB:BridgeHasCapability("INVENTORY_EXACT_V1") then MB:RefreshDomain("BOT.INVENTORY_EXACT", botName) end
                    if descriptor.family == "ITEM_ACTION" and tx.itemAction == "BANK_DEPOSIT" then MB:RefreshDomain("BOT.BANK", botName) end
                    if descriptor.family == "ITEM_ACTION" and tx.itemAction == "GBANK_DEPOSIT" then MB:RefreshDomain("BOT.GUILD_BANK", botName) end
                    if descriptor.family == "ITEM_BUYBACK" and MB:BridgeHasCapability("VENDOR_BUYBACK_V1") then MB:RefreshDomain("BOT.BUYBACK", botName) end
                end)
            end
        end
        if descriptor.family == "TALENT_SPEC_APPLY" then
            local bot = tx.targets and tx.targets[1]
            if bot then
                local botName = bot.name
                self:After(0.25, function()
                    MB:RefreshDomain("BOT.TALENT_SPECS", botName)
                    MB:RefreshDomain("BOT.TALENTS", botName)
                    MB:RefreshDomain("BOT.DETAIL", botName)
                    MB:RefreshDomain("BOT.STATE", botName)
                    MB:RefreshDomain("BOT.SPELLBOOK", botName)
                    MB:RefreshDomain("BOT.GLYPHS", botName)
                end)
            end
        end
        if self.ApplyRTIConfirmation then self:ApplyRTIConfirmation(tx) end
    else
        local errorCode = result and self:Trim(result.reason) or ""
        if errorCode == "" and result then errorCode = self:Trim(result.status) end
        if errorCode == "" and result then errorCode = self:Trim(result.result) end
        if errorCode == "" then errorCode = "FAILED" end
        self:SetTransactionState(tx, "FAILED", { error = errorCode })
    end
    if type(tx.callback) == "function" then self:SafeCall(tx.callback, self:TransactionSnapshot(tx)) end
    return true
end

function MB:AbortPendingActions(reason)
    if self.AbortQuestWorkflows then self:AbortQuestWorkflows(reason) end
    if self.AbortLifecycleWorkflows then self:AbortLifecycleWorkflows(reason) end
    if self.AbortQuestAcceptWorkflows then self:AbortQuestAcceptWorkflows(reason) end
    -- Verification workers must never survive into a new bridge/session epoch.
    self.itemVerificationByBot = {}
    if self.ClearWhisperPresentationSuppression then self:ClearWhisperPresentationSuppression(nil, nil, reason or "SESSION_RESET") end
    if self.tradeGive then
        self.tradeGive.pending = nil
        self.tradeGive.active = {}
    end
    reason = self:Trim(reason)
    if reason == "" then reason = "SESSION_RESET" end
    local now = self:Now()
    local pending = {}
    for _, tx in pairs(self.transactions) do
        if tx.sessionEpoch == self.sessionEpoch and (tx.state == "QUEUED" or tx.state == "DISPATCHING" or tx.state == "SENT" or tx.state == "SENT_UNVERIFIED" or tx.state == "AWAITING_CONFIRMATION") then
            pending[#pending + 1] = tx
        end
    end
    for _, tx in ipairs(pending) do
        if tx.bridgeToken then self.bridge.actionTokens[tx.bridgeToken] = nil end
        tx.completedAt = now
        self.runtime.counters.actionsCompleted = self.runtime.counters.actionsCompleted + 1
        local state = (tx.state == "SENT" or tx.state == "SENT_UNVERIFIED" or tx.state == "AWAITING_CONFIRMATION") and "AMBIGUOUS" or "CANCELLED"
        self:SetTransactionState(tx, state, { error = reason })
        if type(tx.callback) == "function" then self:SafeCall(tx.callback, self:TransactionSnapshot(tx)) end
    end
    return #pending
end

function MB:RunActionTimeouts()
    local now = self:Now()
    for _, tx in pairs(self.transactions) do
        if (tx.state == "SENT" or tx.state == "AWAITING_CONFIRMATION") and tx.expiresAt and now >= tx.expiresAt then
            local descriptor = self.actions[tx.actionId] or {}
            if descriptor.family == "BOT_LIFECYCLE" and self.OnBotLifecycleTimeout then self:OnBotLifecycleTimeout(tx)
            elseif tx.bridgeToken then self.bridge.actionTokens[tx.bridgeToken] = nil end
            tx.completedAt = now
            local ambiguous = descriptor.idempotency == "NON_IDEMPOTENT" or descriptor.idempotency == "BEST_EFFORT_ORDER" or (descriptor.family == "ITEM_SEMANTIC" and tx.transportRoute == "BRIDGE_NATIVE")
            self:SetTransactionState(tx, ambiguous and "AMBIGUOUS" or "FAILED", { error = "TIMEOUT" })
            if type(tx.callback) == "function" then self:SafeCall(tx.callback, self:TransactionSnapshot(tx)) end
        end
    end
end

function MB:GetTransaction(id)
    return self:TransactionSnapshot(self.transactions[id])
end
