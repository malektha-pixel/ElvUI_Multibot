local _, MB = ...

MB.RTI_ICONS = {
    { key = "star", id = 1, label = "Star", texture = "Interface\\TARGETINGFRAME\\UI-RaidTargetingIcon_1" },
    { key = "circle", id = 2, label = "Circle", texture = "Interface\\TARGETINGFRAME\\UI-RaidTargetingIcon_2" },
    { key = "diamond", id = 3, label = "Diamond", texture = "Interface\\TARGETINGFRAME\\UI-RaidTargetingIcon_3" },
    { key = "triangle", id = 4, label = "Triangle", texture = "Interface\\TARGETINGFRAME\\UI-RaidTargetingIcon_4" },
    { key = "moon", id = 5, label = "Moon", texture = "Interface\\TARGETINGFRAME\\UI-RaidTargetingIcon_5" },
    { key = "square", id = 6, label = "Square", texture = "Interface\\TARGETINGFRAME\\UI-RaidTargetingIcon_6" },
    { key = "cross", id = 7, label = "Cross", texture = "Interface\\TARGETINGFRAME\\UI-RaidTargetingIcon_7" },
    { key = "skull", id = 8, label = "Skull", texture = "Interface\\TARGETINGFRAME\\UI-RaidTargetingIcon_8" },
}

local RTI_BY_KEY, RTI_BY_ID = {}, {}
for _, icon in ipairs(MB.RTI_ICONS) do RTI_BY_KEY[icon.key] = icon; RTI_BY_ID[icon.id] = icon end

function MB:NormalizeRTIPurpose(value)
    value = self:Upper(value)
    if value == "PRIORITY" or value == "ATTACK" or value == "PRIMARY" then return "PRIORITY" end
    if value == "CC" or value == "CROWD_CONTROL" then return "CC" end
    return nil, "INVALID_RTI_PURPOSE"
end

function MB:NormalizeRTIIcon(value)
    if type(value) == "table" then value = value.key or value.id end
    local numeric = tonumber(value)
    local icon = numeric and RTI_BY_ID[numeric] or RTI_BY_KEY[self:Lower(value)]
    if not icon then return nil, "INVALID_RTI_ICON" end
    return self:Copy(icon)
end

function MB:GetRTIIcons() return self:Copy(self.RTI_ICONS) end


function MB:ResetTacticalSessionState(reason)
    reason = reason or "SESSION_RESET"
    local cleared = 0
    local sessionDomains = {
        ["BOT.RTI"] = true,
        ["BOT.CC_RTI"] = true,
        ["CORE.RTI_ASSIGNMENTS"] = true,
        ["CORE.RTSC_PLACEMENT"] = true,
    }
    for key, entry in pairs(self.cache or {}) do
        local domain = entry and entry.meta and entry.meta.domain
        if domain and sessionDomains[domain] then
            local targetKey = entry.meta.targetKey or "GLOBAL"
            self.cache[key] = nil
            cleared = cleared + 1
            self:Emit("MB_DATA_INVALIDATED", domain, targetKey, reason)
        end
    end
    self:Emit("MB_RTI_ASSIGNMENTS_CHANGED", reason, { authority = "BRIDGE_ACKED_CLIENT_STATE", externalChangesObservable = false, bots = {}, icons = {}, warnings = {}, warningCount = 0 })
    return cleared
end

function MB:GetRTIAssignment(botRef, purpose)
    local bot = self:ResolveBot(botRef)
    if not bot then return nil, "BOT_NOT_FOUND" end
    local normalized, err = self:NormalizeRTIPurpose(purpose)
    if not normalized then return nil, err end
    return self:GetData(normalized == "CC" and "BOT.CC_RTI" or "BOT.RTI", bot.key)
end

function MB:GetRTISemantics(purpose)
    local normalized = self:NormalizeRTIPurpose(purpose)
    if normalized == "PRIORITY" then
        return { purpose = "PRIORITY", label = "Priority Target", behavior = "ACTIVE_COMBAT_PREFERENCE", mayInfluenceAutomation = true, mayAutoEngageMarkedHostile = true }
    elseif normalized == "CC" then
        return { purpose = "CC", label = "CC Target", behavior = "CC_TARGET_PREFERENCE", mayInfluenceAutomation = true, mayTriggerCCAutomation = true }
    end
    return nil
end

local function assignmentValue(self, bot, purpose, icon, tx)
    return {
        botKey = bot.key, botName = bot.name, purpose = purpose,
        icon = icon.key, iconId = icon.id, label = icon.label, texture = icon.texture,
        assignedAt = self:Now(), transactionId = tx and tx.id or nil,
        authority = "BRIDGE_ACKED_CLIENT_STATE", externalChangesObservable = false,
        semantics = self:GetRTISemantics(purpose),
    }
end

function MB:RebuildRTISummary(reason)
    local summary = { authority = "BRIDGE_ACKED_CLIENT_STATE", externalChangesObservable = false, bots = {}, icons = {}, warnings = {}, reason = reason }
    for _, icon in ipairs(self.RTI_ICONS) do summary.icons[icon.key] = { icon = icon.key, iconId = icon.id, label = icon.label, priorityBots = {}, ccBots = {} } end
    for _, bot in ipairs(self:GetBots()) do
        local priority = self:GetData("BOT.RTI", bot.key)
        local cc = self:GetData("BOT.CC_RTI", bot.key)
        if priority or cc then summary.bots[bot.key] = { key = bot.key, name = bot.name, priority = priority and priority.icon or nil, cc = cc and cc.icon or nil } end
        if priority and summary.icons[priority.icon] then summary.icons[priority.icon].priorityBots[#summary.icons[priority.icon].priorityBots + 1] = { key = bot.key, name = bot.name } end
        if cc and summary.icons[cc.icon] then summary.icons[cc.icon].ccBots[#summary.icons[cc.icon].ccBots + 1] = { key = bot.key, name = bot.name } end
    end
    for _, slot in pairs(summary.icons) do
        table.sort(slot.priorityBots, function(a, b) return self:Lower(a.name) < self:Lower(b.name) end)
        table.sort(slot.ccBots, function(a, b) return self:Lower(a.name) < self:Lower(b.name) end)
        slot.priorityCount, slot.ccCount = #slot.priorityBots, #slot.ccBots
        if slot.priorityCount > 0 and slot.ccCount > 0 then
            summary.warnings[#summary.warnings + 1] = { code = "RTI_MIXED_PURPOSE_ICON", severity = "DANGER", icon = slot.icon, message = slot.label .. " is assigned for both priority and CC." }
        end
    end
    for _, item in pairs(summary.bots) do
        if item.priority and item.cc and item.priority == item.cc then summary.warnings[#summary.warnings + 1] = { code = "RTI_SAME_BOT_PRIORITY_AND_CC", severity = "DANGER", botKey = item.key, botName = item.name, icon = item.priority, message = item.name .. " has the same icon assigned for priority and CC." } end
    end
    summary.warningCount = #summary.warnings
    self:CommitData("CORE.RTI_ASSIGNMENTS", "GLOBAL", summary, { source = "DERIVED", authority = "BRIDGE_ACKED_CLIENT_STATE" })
    self:Emit("MB_RTI_ASSIGNMENTS_CHANGED", reason or "UPDATED", self:Copy(summary))
    return summary
end

function MB:ApplyRTIConfirmation(tx)
    local descriptor = tx and self.actions[tx.actionId]
    if not descriptor or descriptor.family ~= "RTI" or not descriptor.semanticKind then return false end
    if descriptor.semanticKind ~= "ASSIGN_PRIORITY" and descriptor.semanticKind ~= "ASSIGN_CC" then return false end
    local bot = tx.targets and tx.targets[1]
    local icon = self:NormalizeRTIIcon(tx.args and tx.args.icon)
    if not bot or not icon then return false end
    local purpose = descriptor.semanticKind == "ASSIGN_CC" and "CC" or "PRIORITY"
    self:CommitData(purpose == "CC" and "BOT.CC_RTI" or "BOT.RTI", bot.key, assignmentValue(self, bot, purpose, icon, tx), { source = "BRIDGE_ACK", authority = "BRIDGE_ACKED_CLIENT_STATE" })
    self:RebuildRTISummary("ASSIGNMENT_CONFIRMED")
    return true
end

function MB:GetRTIAssignmentSummary()
    local summary = self:GetData("CORE.RTI_ASSIGNMENTS", "GLOBAL")
    if not summary then summary = self:RebuildRTISummary("ON_DEMAND") end
    return summary
end

function MB:PreviewRTIAssignment(targetSpec, purpose, iconValue)
    local normalized, err = self:NormalizeRTIPurpose(purpose)
    if not normalized then return nil, err end
    local icon, iconErr = self:NormalizeRTIIcon(iconValue)
    if not icon then return nil, iconErr end
    local bots, targetInfo, targetErr = self:ResolveTargetSpec(targetSpec)
    if not bots then return nil, targetErr end
    if #bots == 0 then return nil, "NO_TARGETS" end

    local before = self:GetRTIAssignmentSummary() or { warnings = {} }
    local preview = self:Copy(before)
    preview.bots = preview.bots or {}; preview.icons = preview.icons or {}; preview.warnings = {}
    for _, bot in ipairs(bots) do
        local item = preview.bots[bot.key] or { key = bot.key, name = bot.name }
        if normalized == "CC" then item.cc = icon.key else item.priority = icon.key end
        preview.bots[bot.key] = item
    end
    for _, slot in pairs(preview.icons) do slot.priorityBots, slot.ccBots = {}, {} end
    for _, item in pairs(preview.bots) do
        if item.priority and preview.icons[item.priority] then preview.icons[item.priority].priorityBots[#preview.icons[item.priority].priorityBots + 1] = { key = item.key, name = item.name } end
        if item.cc and preview.icons[item.cc] then preview.icons[item.cc].ccBots[#preview.icons[item.cc].ccBots + 1] = { key = item.key, name = item.name } end
        if item.priority and item.cc and item.priority == item.cc then preview.warnings[#preview.warnings + 1] = { code = "RTI_SAME_BOT_PRIORITY_AND_CC", severity = "DANGER", botKey = item.key, icon = item.priority } end
    end
    for _, slot in pairs(preview.icons) do if #slot.priorityBots > 0 and #slot.ccBots > 0 then preview.warnings[#preview.warnings + 1] = { code = "RTI_MIXED_PURPOSE_ICON", severity = "DANGER", icon = slot.icon } end end
    local beforeSet, introduced = {}, {}
    for _, warning in ipairs(before.warnings or {}) do beforeSet[tostring(warning.code) .. ":" .. tostring(warning.icon) .. ":" .. tostring(warning.botKey)] = true end
    for _, warning in ipairs(preview.warnings or {}) do local key = tostring(warning.code) .. ":" .. tostring(warning.icon) .. ":" .. tostring(warning.botKey); if not beforeSet[key] then introduced[#introduced + 1] = self:Copy(warning) end end
    return { purpose = normalized, icon = icon, targets = self:Copy(bots), targetInfo = self:Copy(targetInfo), warnings = preview.warnings, introducedWarnings = introduced, safe = #introduced == 0 }
end

function MB:AssignRTI(originModule, targetSpec, purpose, iconValue, callback)
    local normalized, err = self:NormalizeRTIPurpose(purpose)
    if not normalized then return nil, err end
    local icon, iconErr = self:NormalizeRTIIcon(iconValue)
    if not icon then return nil, iconErr end
    return self:ExecuteActionSet(originModule, normalized == "CC" and "RTI.ASSIGN_CC" or "RTI.ASSIGN_PRIORITY", targetSpec, { icon = icon.key }, callback)
end

function MB:RunAssignedRTI(originModule, targetSpec, mode, callback)
    mode = self:Upper(mode)
    local actionId = mode == "PULL" and "RTI.PULL_ASSIGNED" or (mode == "ATTACK" and "RTI.ATTACK_ASSIGNED" or nil)
    if not actionId then return nil, "INVALID_RTI_MODE" end
    return self:ExecuteActionSet(originModule, actionId, targetSpec, {}, callback)
end

function MB:OrderBots(originModule, targetSpec, order, callback)
    return self:ExecuteAction(originModule, "TACTICAL.ORDER", targetSpec, { scope = "SET", order = order }, callback)
end

function MB:GetRTSCPlacementContract()
    return {
        secureActionRequired = true,
        secureType = "macro",
        macroText = "/cast aedm",
        spellCommand = "aedm",
        slots = 9,
        note = "The frontend owns the SecureActionButtonTemplate. The Core prepares Playerbots RTSC state and never creates gameplay UI.",
    }
end

function MB:EnableRTSC(originModule, callback)
    return self:ExecuteAction(originModule, "RTSC.ENABLE", "all", {}, callback)
end

function MB:PrepareRTSCPlacement(originModule, targetSpec, slot, callback)
    slot = tonumber(slot) or 0
    if slot < 0 or slot > 9 then return nil, "INVALID_RTSC_SLOT" end
    return self:ExecuteAction(originModule, "RTSC.PREPARE", targetSpec, { slot = slot }, callback)
end

function MB:SelectRTSCTargets(originModule, targetSpec, callback)
    return self:ExecuteAction(originModule, "RTSC.SELECT", targetSpec, {}, callback)
end

function MB:GoRTSCLocation(originModule, targetSpec, slot, callback)
    return self:ExecuteAction(originModule, "RTSC.GO", targetSpec, { slot = slot }, callback)
end

function MB:SaveRTSCLocation(originModule, slot, callback)
    return self:ExecuteAction(originModule, "RTSC.SAVE", "all", { slot = slot }, callback)
end

-- Secure AEDM placement is special: the chat-side slot arm must reach the
-- server before the same hardware click executes /cast aedm.  The normal
-- transaction/sequence path is intentionally asynchronous and can therefore
-- race the secure cast.  This narrow Core-owned primitive performs only the
-- validated RTSC unsave/save preparation synchronously from the click handler.
-- It is not a general arbitrary-chat escape hatch.
function MB:ArmRTSCLocationImmediate(originModule, slot, clearFirst)
    originModule = self:Trim(originModule)
    if originModule == "" then return false, "MODULE_REQUIRED" end
    if not self.modules[originModule] then self:RegisterModule(originModule) end

    slot = tonumber(slot)
    if not slot or slot < 1 or slot > 9 or math.floor(slot) ~= slot then
        return false, "INVALID_RTSC_SLOT"
    end
    if not self.db or not self.db.chat or not self.db.chat.enabled then
        return false, "CHAT_DISABLED"
    end
    if type(SendChatMessage) ~= "function" then return false, "SEND_CHAT_UNAVAILABLE" end
    if not self:ChatGroupChannel() then return false, "GROUP_REQUIRED" end

    local sent, err
    if clearFirst == true then
        sent, err = self:ChatSendGroupCommand("rtsc unsave " .. tostring(slot), true)
        if not sent then return false, err or "RTSC_UNSAVE_SEND_FAILED" end
    end

    sent, err = self:ChatSendGroupCommand("rtsc save " .. tostring(slot), true)
    if not sent then return false, err or "RTSC_SAVE_SEND_FAILED" end

    local placement = {
        status = "SAVE_ARMED_IMMEDIATE",
        slot = slot,
        targets = {},
        targetInfo = { kind = "GROUP", selector = "all" },
        contract = self:GetRTSCPlacementContract(),
        preparedAt = self:Now(),
        clearFirst = clearFirst == true,
        originModule = originModule,
        authority = "BEST_EFFORT_SENT",
    }
    self:CommitData("CORE.RTSC_PLACEMENT", "GLOBAL", placement, { source = "CHAT", authority = "BEST_EFFORT_SENT" })
    self:Emit("MB_RTSC_PLACEMENT_PREPARED", self:Copy(placement))
    return true, self:Copy(placement)
end

function MB:UnsaveRTSCLocation(originModule, slot, callback)
    return self:ExecuteAction(originModule, "RTSC.UNSAVE", "all", { slot = slot }, callback)
end

function MB:CancelRTSC(originModule, callback)
    return self:ExecuteAction(originModule, "RTSC.CANCEL", "all", {}, callback)
end

function MB:RTSCStrategies(originModule, targetSpec, enabled, callback)
    local change = enabled == false and "-rtsc,-guard" or "+rtsc,+guard"
    local combat = self:ExecuteActionSet(originModule, "STRATEGY.MUTATE", targetSpec, { stateScope = "C", changes = change }, callback)
    local normal = self:ExecuteActionSet(originModule, "STRATEGY.MUTATE", targetSpec, { stateScope = "N", changes = change }, callback)
    return { combat = combat, normal = normal }
end
