local BotInspect = _G.ElvUI_Multibot_BotInspect
if not BotInspect then return end

local MODULE = "ElvUI_Multibot_BotInspect"
local API = BotInspect.api

local VIEW_GEAR = "GEAR"
local VIEW_SPELLBOOK = "SPELLBOOK"
local VIEW_QUESTS = "QUESTS"
local SPELL_VISIBLE_ROWS = 12
local SPELL_ROW_HEIGHT = 31
local SPELL_IGNORE_QUERY_TIMEOUT = 5.0

local function trim(value)
    value = tostring(value or "")
    return (string.gsub(value, "^%s*(.-)%s*$", "%1"))
end

local function lower(value) return string.lower(tostring(value or "")) end

local function normalizeBotName(value)
    value = trim(value)
    value = string.match(value, "^[^-]+") or value
    return lower(value)
end

local function now()
    return type(GetTime) == "function" and GetTime() or 0
end

local function ignoredStateFor(botName)
    local key = normalizeBotName(botName)
    if key == "" then return nil end
    BotInspect.spellIgnoredState = BotInspect.spellIgnoredState or {}
    return BotInspect.spellIgnoredState[key]
end

local function createBackdrop(frame, alpha)
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        tile = true, tileSize = 8, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    frame:SetBackdropColor(0.025, 0.027, 0.035, alpha or 0.88)
    frame:SetBackdropBorderColor(0.18, 0.19, 0.23, 1)
end

local function createText(parent, size, justifyH)
    local text = parent:CreateFontString(nil, "OVERLAY")
    text:SetFont("Fonts\\FRIZQT__.TTF", size or 10, "OUTLINE")
    text:SetJustifyH(justifyH or "LEFT")
    text:SetJustifyV("MIDDLE")
    text:SetTextColor(0.86, 0.86, 0.88)
    return text
end

local function createButton(parent, text, width, height)
    local button = CreateFrame("Button", nil, parent)
    button:SetWidth(width or 80); button:SetHeight(height or 20)
    createBackdrop(button, 0.82)
    local label = createText(button, 9, "CENTER")
    label:SetPoint("TOPLEFT", button, "TOPLEFT", 4, -2)
    label:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -4, 2)
    label:SetText(text or "")
    button.label = label
    button:SetScript("OnEnter", function(self)
        if self.enabled ~= false then self:SetBackdropBorderColor(0.25, 0.65, 0.95, 1) end
    end)
    button:SetScript("OnLeave", function(self)
        if self.enabled ~= false then self:SetBackdropBorderColor(0.18, 0.19, 0.23, 1) end
    end)
    return button
end

local function setButtonEnabled(button, enabled)
    if not button then return end
    button.enabled = enabled == true
    button:EnableMouse(enabled == true)
    if button.label then
        local value = enabled and 0.90 or 0.48
        button.label:SetTextColor(value, value, enabled and 0.92 or 0.50)
    end
    button:SetBackdropBorderColor(enabled and 0.18 or 0.10, enabled and 0.19 or 0.10, enabled and 0.23 or 0.12, 1)
end

local function getSpellDisplay(spellId)
    spellId = tonumber(spellId) or 0
    if spellId <= 0 then return nil, nil, nil end
    if type(GetSpellInfo) == "function" then
        local name, rank, icon = GetSpellInfo(spellId)
        return name, rank, icon
    end
    return nil, nil, nil
end

local function buildSpellRows(spellbook, query)
    local rows, byName = {}, {}
    query = lower(trim(query))
    for _, rawId in ipairs(type(spellbook) == "table" and spellbook.spellIds or {}) do
        local spellId = tonumber(rawId) or 0
        if spellId > 0 then
            local name, rank, icon = getSpellDisplay(spellId)
            name = name or ("Spell " .. tostring(spellId))
            rank = rank or ""
            local rankNumber = tonumber(string.match(rank, "(%d+)") or "0") or 0
            local key = lower(name)
            local current = byName[key]
            if not current or rankNumber > current.rankNumber or (rankNumber == current.rankNumber and spellId > current.spellId) then
                byName[key] = { spellId = spellId, name = name, rank = rank, rankNumber = rankNumber, icon = icon }
            end
        end
    end
    for _, entry in pairs(byName) do
        local haystack = lower(entry.name .. " " .. tostring(entry.rank or "") .. " " .. tostring(entry.spellId))
        if query == "" or string.find(haystack, query, 1, true) then rows[#rows + 1] = entry end
    end
    table.sort(rows, function(a, b)
        local an, bn = lower(a.name), lower(b.name)
        if an ~= bn then return an < bn end
        if a.rankNumber ~= b.rankNumber then return a.rankNumber > b.rankNumber end
        return a.spellId < b.spellId
    end)
    return rows
end

local function statusTextForSource(source)
    if source == "LIVE" then return "LIVE" end
    if source == "HISTORICAL_FALLBACK" then return "LAST OBSERVED · refreshing" end
    if source == "HISTORICAL" then return "LAST OBSERVED" end
    if source == "LIVE_PENDING" then return "WAITING FOR LIVE DATA" end
    return "NO DATA"
end

function BotInspect:SetActiveView(view)
    if view ~= VIEW_SPELLBOOK and view ~= VIEW_QUESTS then view = VIEW_GEAR end
    if self.activeView == view then
        self:ApplyActiveView()
        return
    end
    self.activeView = view
    self.spellbookOffset = 0
    self.questOffset = 0
    self:CancelSelectedReliabilityJobs()
    self:ApplyActiveView()
    self:UpdateInterests()
    self:RenderAll()
    if self.selectedBot and self:IsSelectedBotOnline() and self.frame and self.frame:IsShown() then
        self:ScheduleSelectedEnsure(0.15, false)
        if view == VIEW_SPELLBOOK then self:RequestSpellIgnoredList(self.selectedBot)
        elseif view == VIEW_QUESTS and type(self.RefreshSelectedQuests) == "function" then self:RefreshSelectedQuests(true) end
    end
end

function BotInspect:ApplyActiveView()
    if not self.frame then return end
    local spellbook = self.activeView == VIEW_SPELLBOOK
    local quests = self.activeView == VIEW_QUESTS
    if self.frame.gearView then if self.activeView == VIEW_GEAR then self.frame.gearView:Show() else self.frame.gearView:Hide() end end
    if self.frame.spellbookView then
        if spellbook then self.frame.spellbookView:Show() else self.frame.spellbookView:Hide() end
        if self.frame.spellbookView.spellSearch then
            if spellbook then self.frame.spellbookView.spellSearch:Show() else self.frame.spellbookView.spellSearch:Hide() end
        end
    end
    if self.frame.questsView then if quests then self.frame.questsView:Show() else self.frame.questsView:Hide() end end
    local tabs = self.frame.viewTabs or {}
    if tabs.gear and tabs.gear.label then
        local active = self.activeView == VIEW_GEAR
        tabs.gear.label:SetTextColor(active and 0.25 or 0.76, active and 0.78 or 0.76, active and 1.0 or 0.80)
        tabs.gear:SetBackdropColor(active and 0.05 or 0.03, active and 0.12 or 0.03, active and 0.18 or 0.04, 0.92)
    end
    if tabs.spellbook and tabs.spellbook.label then
        tabs.spellbook.label:SetTextColor(spellbook and 0.25 or 0.76, spellbook and 0.78 or 0.76, spellbook and 1.0 or 0.80)
        tabs.spellbook:SetBackdropColor(spellbook and 0.05 or 0.03, spellbook and 0.12 or 0.03, spellbook and 0.18 or 0.04, 0.92)
    end
    if tabs.quests and tabs.quests.label then
        tabs.quests.label:SetTextColor(quests and 0.25 or 0.76, quests and 0.78 or 0.76, quests and 1.0 or 0.80)
        tabs.quests:SetBackdropColor(quests and 0.05 or 0.03, quests and 0.12 or 0.03, quests and 0.18 or 0.04, 0.92)
    end
end

function BotInspect:BuildViewTabs(parent)
    local gear = createButton(parent, "Gear & Inventory", 118, 22)
    gear:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, -69)
    gear:SetScript("OnClick", function() BotInspect:SetActiveView(VIEW_GEAR) end)
    local spellbook = createButton(parent, "Spellbook", 92, 22)
    spellbook:SetPoint("LEFT", gear, "RIGHT", 5, 0)
    spellbook:SetScript("OnClick", function() BotInspect:SetActiveView(VIEW_SPELLBOOK) end)
    local quests = createButton(parent, "Quests", 92, 22)
    quests:SetPoint("LEFT", spellbook, "RIGHT", 5, 0)
    quests:SetScript("OnClick", function() BotInspect:SetActiveView(VIEW_QUESTS) end)
    parent.viewTabs = { gear = gear, spellbook = spellbook, quests = quests }
    self.activeView = self.activeView or VIEW_GEAR
    self:ApplyActiveView()
end

function BotInspect:BuildSpellbookArea(parent)
    local root = CreateFrame("Frame", nil, parent)
    root:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    root:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)
    root:Hide()
    self.frame.spellbookView = root

    local panel = CreateFrame("Frame", nil, root)
    panel:SetPoint("TOPLEFT", root, "TOPLEFT", 0, 0)
    panel:SetPoint("BOTTOMRIGHT", root, "BOTTOMRIGHT", 0, 0)
    createBackdrop(panel, 0.42)
    root.spellPanel = panel

    local heading = createText(panel, 13, "LEFT")
    heading:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -8)
    heading:SetText("Spellbook")

    local sourceText = createText(panel, 8, "LEFT")
    sourceText:SetPoint("TOPLEFT", panel, "TOPLEFT", 82, -10)
    sourceText:SetWidth(320)
    sourceText:SetTextColor(0.62, 0.64, 0.68)
    root.sourceText = sourceText

    local spellSummary = createText(panel, 8, "RIGHT")
    spellSummary:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -10, -10)
    spellSummary:SetWidth(120)
    spellSummary:SetTextColor(0.62, 0.64, 0.68)
    root.spellSummary = spellSummary

    local search = CreateFrame("EditBox", nil, panel)
    search:SetWidth(712); search:SetHeight(20)
    search:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -29)
    search:SetAutoFocus(false); search:SetMaxLetters(48)
    search:SetFont("Fonts\\FRIZQT__.TTF", 9, "")
    search:SetTextColor(0.88, 0.88, 0.90)
    search:SetTextInsets(6, 6, 0, 0)
    createBackdrop(search, 0.72)
    local searchHint = createText(search, 8, "LEFT")
    searchHint:SetPoint("LEFT", search, "LEFT", 6, 0)
    searchHint:SetText("Search spells...")
    searchHint:SetTextColor(0.42, 0.45, 0.50)
    search.hint = searchHint
    search:SetScript("OnTextChanged", function(self)
        if self.hint then if trim(self:GetText()) == "" and not self:HasFocus() then self.hint:Show() else self.hint:Hide() end end
        BotInspect.spellbookOffset = 0
        BotInspect:RenderSpellbook()
    end)
    search:SetScript("OnEditFocusGained", function(self) if self.hint then self.hint:Hide() end end)
    search:SetScript("OnEditFocusLost", function(self) if self.hint and trim(self:GetText()) == "" then self.hint:Show() end end)
    search:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    root.spellSearch = search

    local list = CreateFrame("Frame", nil, panel)
    list:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -56)
    list:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -22, 9)
    root.spellList = list

    root.spellRows = {}
    for i = 1, SPELL_VISIBLE_ROWS do
        local row = CreateFrame("Button", nil, list)
        row:SetHeight(SPELL_ROW_HEIGHT - 2)
        row:SetPoint("TOPLEFT", list, "TOPLEFT", 0, -((i - 1) * SPELL_ROW_HEIGHT))
        row:SetPoint("RIGHT", list, "RIGHT", 0, 0)
        createBackdrop(row, 0.28)
        row:RegisterForClicks("LeftButtonUp")
        row:RegisterForDrag("LeftButton")

        local icon = row:CreateTexture(nil, "ARTWORK")
        icon:SetWidth(24); icon:SetHeight(24); icon:SetPoint("LEFT", row, "LEFT", 3, 0)
        icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        row.icon = icon

        local name = createText(row, 9, "LEFT")
        name:SetPoint("TOPLEFT", row, "TOPLEFT", 32, -4); name:SetWidth(560)
        row.nameText = name
        local rank = createText(row, 7, "LEFT")
        rank:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 32, 3); rank:SetWidth(560); rank:SetTextColor(0.58, 0.62, 0.68)
        row.rankText = rank

        local auto = createButton(row, "CHECKING", 66, 20)
        auto:SetPoint("RIGHT", row, "RIGHT", -3, 0)
        auto.label:SetFont("Fonts\\FRIZQT__.TTF", 7, "OUTLINE")
        auto:SetScript("OnClick", function(self)
            if self.enabled == false or not self.spellId then return end
            BotInspect:ToggleSpellAutoUse(self.spellId, self.spellName)
        end)
        auto:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:ClearLines()
            GameTooltip:AddLine("Autonomous spell use", 1, 1, 1)
            GameTooltip:AddLine(tostring(self.autoDescription or "State unknown."), 0.72, 0.76, 0.82, true)
            if self.enabled ~= false then GameTooltip:AddLine("Click to toggle whether Playerbots may use this spell autonomously.", 0.35, 0.80, 1.0, true) end
            GameTooltip:AddLine("The ignored-spell list is read once when this bot's Spellbook is entered.", 0.55, 0.60, 0.68, true)
            GameTooltip:AddLine("* = a change was requested after the last list read.", 0.90, 0.70, 0.25, true)
            GameTooltip:Show()
            if self.enabled ~= false then self:SetBackdropBorderColor(0.25, 0.65, 0.95, 1) end
        end)
        auto:SetScript("OnLeave", function(self)
            GameTooltip:Hide()
            if self.enabled ~= false then self:SetBackdropBorderColor(0.18, 0.19, 0.23, 1) end
        end)
        row.autoButton = auto

        row:SetScript("OnClick", function(self)
            if self.spellId then BotInspect:CastSelectedBotSpell(self.spellId, self.spellName) end
        end)
        row:SetScript("OnDragStart", function(self)
            if self.spellId then BotInspect:PickupSelectedBotSpell(self.spellId, self.spellName, self.spellIcon) end
        end)
        row:SetScript("OnEnter", function(self)
            if not self.spellId then return end
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            local ok = false
            if type(GameTooltip.SetHyperlink) == "function" then ok = pcall(GameTooltip.SetHyperlink, GameTooltip, "spell:" .. tostring(self.spellId)) end
            if not ok then GameTooltip:ClearLines(); GameTooltip:AddLine(self.spellName or ("Spell " .. tostring(self.spellId)), 1, 1, 1) end
            GameTooltip:AddLine("Left-click: request this bot cast the spell now.", 0.35, 0.80, 1.0)
            GameTooltip:AddLine("Drag: create/reuse a bot-spell macro and place it on an ElvUI/Blizzard action bar.", 0.35, 0.80, 1.0, true)
            GameTooltip:AddLine("Spell ID " .. tostring(self.spellId), 0.55, 0.60, 0.68)
            GameTooltip:Show()
            self:SetBackdropBorderColor(0.25, 0.65, 0.95, 1)
        end)
        row:SetScript("OnLeave", function(self) GameTooltip:Hide(); self:SetBackdropBorderColor(0.18, 0.19, 0.23, 1) end)
        root.spellRows[i] = row
    end

    local slider = CreateFrame("Slider", nil, panel)
    slider:SetOrientation("VERTICAL"); slider:SetWidth(12)
    slider:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -5, -60)
    slider:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -5, 12)
    slider:SetMinMaxValues(0, 0); slider:SetValueStep(1); slider:SetValue(0)
    slider:SetThumbTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
    local thumb = slider:GetThumbTexture(); if thumb then thumb:SetWidth(18); thumb:SetHeight(24) end
    slider:SetScript("OnValueChanged", function(self, value)
        if root.updatingSpellSlider then return end
        local maximum = tonumber(root.spellMaxOffset) or 0
        BotInspect.spellbookOffset = math.max(0, math.min(maximum, math.floor((tonumber(value) or 0) + 0.5)))
        BotInspect:RenderSpellbookRows()
    end)
    root.spellSlider = slider

    local function wheel(_, delta)
        local maximum = tonumber(root.spellMaxOffset) or 0
        BotInspect.spellbookOffset = math.max(0, math.min(maximum, (tonumber(BotInspect.spellbookOffset) or 0) - (tonumber(delta) or 0) * 3))
        BotInspect:RenderSpellbookRows()
    end
    panel:EnableMouseWheel(true); panel:SetScript("OnMouseWheel", wheel)
    list:EnableMouseWheel(true); list:SetScript("OnMouseWheel", wheel)
    search:EnableMouseWheel(true); search:SetScript("OnMouseWheel", wheel)
    for _, row in ipairs(root.spellRows) do row:EnableMouseWheel(true); row:SetScript("OnMouseWheel", wheel) end

    return root
end

local function spellAutoPresentation(botName, spellId)
    local state = ignoredStateFor(botName)
    spellId = tonumber(spellId)
    if not botName or not spellId then
        return "UNKNOWN", 0.55, 0.58, 0.64, "Autonomous-use state unavailable."
    end
    if state and state.requested and state.requested[spellId] ~= nil then
        local enabled = state.requested[spellId] == true
        if enabled then return "ALLOWED*", 0.85, 0.75, 0.30, "Allow was requested after the last ignored-spell list read." end
        return "DISABLED*", 0.85, 0.55, 0.30, "Disable was requested after the last ignored-spell list read."
    end
    if state and state.status == "PENDING" then
        return "CHECKING", 0.55, 0.72, 0.95, "Reading the bot's ignored-spell list (ss ?)."
    end
    if state and state.status == "READY" then
        if state.ignored and state.ignored[spellId] then
            return "DISABLED", 0.95, 0.42, 0.32, "This spell was present in the bot's ignored-spell list and is disabled for autonomous use."
        end
        return "ALLOWED", 0.35, 0.90, 0.50, "This learned spell was not present in the bot's ignored-spell list and is allowed for autonomous use."
    end
    if state and state.status == "TIMEOUT" then
        return "UNKNOWN", 0.62, 0.64, 0.70, "Ignored-spell list query timed out. Re-enter the Spellbook to query again."
    end
    return "UNKNOWN", 0.62, 0.64, 0.70, "Ignored-spell state has not been read for this Spellbook visit."
end

function BotInspect:GetSpellIgnoredState(botName)
    return ignoredStateFor(botName)
end

function BotInspect:RequestSpellIgnoredList(botName)
    botName = trim(botName or self.selectedBot)
    if botName == "" or self.activeView ~= VIEW_SPELLBOOK then return false, "SPELLBOOK_NOT_ACTIVE" end
    if not self:IsSelectedBotOnline() or normalizeBotName(botName) ~= normalizeBotName(self.selectedBot) then
        return false, "BOT_OFFLINE"
    end
    if type(SendChatMessage) ~= "function" then return false, "SEND_CHAT_UNAVAILABLE" end

    local key = normalizeBotName(botName)
    self.spellIgnoredState = self.spellIgnoredState or {}
    self.spellIgnoredPending = self.spellIgnoredPending or {}
    local sequence = (tonumber(self.spellIgnoredSequence) or 0) + 1
    self.spellIgnoredSequence = sequence
    local state = {
        botName = botName,
        key = key,
        status = "PENDING",
        ignored = {},
        requested = {},
        requestedAt = now(),
        sequence = sequence,
        source = "PLAYERBOTS_SS_QUERY",
    }
    self.spellIgnoredState[key] = state
    self.spellIgnoredPending[key] = state
    self:CancelLocal("spell-ignore-query-" .. key)

    SendChatMessage("ss ?", "WHISPER", nil, botName)
    self:ScheduleLocal("spell-ignore-query-" .. key, SPELL_IGNORE_QUERY_TIMEOUT, function()
        local pending = BotInspect.spellIgnoredPending and BotInspect.spellIgnoredPending[key] or nil
        if pending == state and pending.status == "PENDING" then
            pending.status = "TIMEOUT"
            pending.timedOutAt = now()
            BotInspect.spellIgnoredPending[key] = nil
            if BotInspect.activeView == VIEW_SPELLBOOK and normalizeBotName(BotInspect.selectedBot) == key then
                BotInspect:RenderSpellbook()
            end
        end
    end)
    self:RenderSpellbook()
    return true
end

function BotInspect:HandleSpellIgnoredReply(message, author)
    local key = normalizeBotName(author)
    local state = self.spellIgnoredPending and self.spellIgnoredPending[key] or nil
    if not state or state.status ~= "PENDING" then return false end
    message = tostring(message or "")
    if not string.find(message, "Ignored ", 1, true) then return false end

    local ignored = {}
    for rawId in string.gmatch(message, "|Hspell:(%d+)") do
        local spellId = tonumber(rawId)
        if spellId then ignored[spellId] = true end
    end
    -- Some Playerbots builds may omit the hyperlink wrapper while retaining spell:<id>.
    if not next(ignored) then
        for rawId in string.gmatch(message, "spell:(%d+)") do
            local spellId = tonumber(rawId)
            if spellId then ignored[spellId] = true end
        end
    end

    state.ignored = ignored
    state.requested = {}
    state.status = "READY"
    state.receivedAt = now()
    state.ignoredCount = 0
    for _ in pairs(ignored) do state.ignoredCount = state.ignoredCount + 1 end
    self.spellIgnoredPending[key] = nil
    self:CancelLocal("spell-ignore-query-" .. key)
    if self.activeView == VIEW_SPELLBOOK and normalizeBotName(self.selectedBot) == key then self:RenderSpellbook() end
    return true
end

function BotInspect:ToggleSpellAutoUse(spellId, spellName)
    spellId = tonumber(spellId)
    if not spellId or not self.selectedBot or not self:IsSelectedBotOnline() then
        self:SetStatus("Spell automation changes require an online bot.", 0.95, 0.65, 0.30)
        return
    end
    self.spellMutationPending = self.spellMutationPending or {}
    if self.spellMutationPending[spellId] then return end
    local state = ignoredStateFor(self.selectedBot)
    local baseline = nil
    if state and state.requested and state.requested[spellId] ~= nil then
        baseline = state.requested[spellId] == true
    elseif state and state.status == "READY" then
        baseline = not (state.ignored and state.ignored[spellId] == true)
    end
    if baseline == nil then
        local current, meta = API:GetBotSpellEnabled(self.selectedBot, spellId)
        meta = type(meta) == "table" and meta or {}
        baseline = current
        if baseline == nil then baseline = meta.requestedEnabled end
    end
    if baseline == nil then baseline = true end
    local desired = not baseline
    local availability = type(API.GetBotSpellEnabledAvailability) == "function" and API:GetBotSpellEnabledAvailability(self.selectedBot, spellId) or nil
    if not availability or availability.enabled ~= true then
        self:SetStatus("Spell auto-use unavailable: " .. tostring(availability and availability.reason or "UNKNOWN"), 1, 0.45, 0.35)
        return
    end
    local botName = self.selectedBot
    self.spellMutationPending[spellId] = true
    self:SetStatus("Requesting " .. tostring(spellName or ("spell " .. spellId)) .. " auto-use " .. (desired and "ON" or "OFF") .. " for " .. tostring(botName) .. "...")
    local txId, err = API:SetBotSpellEnabled(MODULE, botName, spellId, desired, function(tx)
        BotInspect.spellMutationPending[spellId] = nil
        if BotInspect.selectedBot ~= botName then return end
        local state = type(tx) == "table" and tx.state or nil
        if state == "SENT_UNVERIFIED" or state == "CONFIRMED" then
            local listState = ignoredStateFor(botName)
            if listState then
                listState.requested = listState.requested or {}
                listState.requested[spellId] = desired == true
            end
            BotInspect:SetStatus((desired and "Allow" or "Disable") .. " requested for " .. tostring(spellName or spellId) .. ". Re-enter Spellbook for fresh ignored-list readback.", 0.35, 0.85, 0.60)
        else
            local reason = type(tx) == "table" and (tx.error or (tx.result and tx.result.reason) or tx.state) or "SPELL_AUTO_REQUEST_FAILED"
            BotInspect:SetStatus("Spell auto-use request failed: " .. tostring(reason or "UNKNOWN"), 1, 0.45, 0.35)
        end
        BotInspect:RenderSpellbook()
    end)
    if not txId then
        self.spellMutationPending[spellId] = nil
        self:SetStatus("Spell auto-use unavailable: " .. tostring(err or "UNKNOWN"), 1, 0.45, 0.35)
        self:RenderSpellbook()
    end
end

function BotInspect:CastSelectedBotSpell(spellId, spellName)
    spellId = tonumber(spellId)
    if not spellId or not self.selectedBot or not self:IsSelectedBotOnline() then
        self:SetStatus("Spell casting requires an online bot.", 0.95, 0.65, 0.30)
        return
    end
    local availability = type(API.GetBotSpellCastAvailability) == "function" and API:GetBotSpellCastAvailability(self.selectedBot, spellId, { requireSpellbook = true }) or nil
    if not availability or availability.enabled ~= true then
        self:SetStatus("Spell cast unavailable: " .. tostring(availability and availability.reason or "UNKNOWN"), 1, 0.45, 0.35)
        return
    end
    local botName = self.selectedBot
    local txId, err = API:CastBotSpell(MODULE, botName, spellId, { requireSpellbook = true }, function(tx)
        if BotInspect.selectedBot ~= botName then return end
        local state = type(tx) == "table" and tx.state or nil
        if state == "SENT_UNVERIFIED" or state == "CONFIRMED" then
            BotInspect:SetStatus("Requested " .. tostring(botName) .. " cast " .. tostring(spellName or spellId) .. ".", 0.35, 0.85, 0.60)
        else
            local reason = type(tx) == "table" and (tx.error or (tx.result and tx.result.reason) or tx.state) or "SPELL_CAST_FAILED"
            BotInspect:SetStatus("Spell cast failed: " .. tostring(reason or "UNKNOWN"), 1, 0.45, 0.35)
        end
    end)
    if not txId then self:SetStatus("Spell cast unavailable: " .. tostring(err or "UNKNOWN"), 1, 0.45, 0.35) end
end

local function macroIconIndex(texture)
    if not texture or type(GetMacroIcons) ~= "function" then return 1 end
    local icons = {}
    local ok = pcall(GetMacroIcons, icons)
    if not ok then return 1 end
    local target = lower(texture)
    for index, value in ipairs(icons) do if lower(value) == target then return index end end
    return 1
end

local function macroNameFor(contract, suffix)
    local guid = tostring(contract and contract.botGuid or "0")
    local spellId = tostring(contract and contract.spellId or "0")
    guid = string.sub(guid, math.max(1, string.len(guid) - 4))
    spellId = string.sub(spellId, math.max(1, string.len(spellId) - 5))
    local name = "MB" .. guid .. "_" .. spellId
    if suffix and suffix > 0 then name = string.sub(name, 1, 14) .. tostring(suffix) end
    return string.sub(name, 1, 16)
end

function BotInspect:PickupSelectedBotSpell(spellId, spellName, spellIcon)
    spellId = tonumber(spellId)
    if not spellId or not self.selectedBot then return end
    if not self:IsSelectedBotOnline() then
        self:SetStatus("Bot spell actions can only be dragged while the bot is online.", 0.95, 0.65, 0.30)
        return
    end
    if type(InCombatLockdown) == "function" and InCombatLockdown() then
        self:SetStatus("Action-bar macros cannot be created or moved during combat.", 0.95, 0.65, 0.30)
        return
    end
    if type(CreateMacro) ~= "function" or type(PickupMacro) ~= "function" or type(GetMacroInfo) ~= "function" then
        self:SetStatus("Legacy macro APIs are unavailable.", 1, 0.45, 0.35)
        return
    end
    local contract, err = API:GetBotSpellActionContract(self.selectedBot, spellId)
    if type(contract) ~= "table" or contract.kind ~= "MACRO" or trim(contract.macroText) == "" then
        self:SetStatus("Bot spell action unavailable: " .. tostring(err or "NO_MACRO_CONTRACT"), 1, 0.45, 0.35)
        return
    end

    local accountCount, characterCount = 0, 0
    if type(GetNumMacros) == "function" then accountCount, characterCount = GetNumMacros() end
    local maxAccount = tonumber(_G.MAX_ACCOUNT_MACROS) or 36
    local maxCharacter = tonumber(_G.MAX_CHARACTER_MACROS) or 18
    local existingIndex
    for index = 1, maxAccount + maxCharacter do
        local name, _, body = GetMacroInfo(index)
        if name and trim(body) == trim(contract.macroText) then existingIndex = index; break end
    end
    if existingIndex then
        PickupMacro(existingIndex)
        self:SetStatus("Picked up " .. tostring(contract.name or spellName or spellId) .. " for the action bar.", 0.35, 0.85, 0.60)
        return
    end

    if tonumber(characterCount) and tonumber(characterCount) >= maxCharacter then
        self:SetStatus("Character macro slots are full; free one before dragging a new bot spell.", 1, 0.55, 0.30)
        return
    end

    local chosen
    for suffix = 0, 9 do
        local candidate = macroNameFor(contract, suffix)
        local existingName, _, existingBody = GetMacroInfo(candidate)
        if not existingName then chosen = candidate; break end
        if trim(existingBody) == trim(contract.macroText) then chosen = candidate; break end
    end
    if not chosen then
        self:SetStatus("Could not allocate a unique macro name for this bot spell.", 1, 0.45, 0.35)
        return
    end
    local iconIndex = macroIconIndex(contract.icon or spellIcon)
    local macroIndex = CreateMacro(chosen, iconIndex, contract.macroText, true)
    if not macroIndex then
        self:SetStatus("Could not create the bot-spell macro; your macro slots may be full.", 1, 0.45, 0.35)
        return
    end
    PickupMacro(macroIndex)
    self:SetStatus("Picked up " .. tostring(contract.name or spellName or spellId) .. ". Drop it on an ElvUI/Blizzard action bar.", 0.35, 0.85, 0.60)
end

function BotInspect:RenderSpellbookRows()
    local root = self.frame and self.frame.spellbookView
    if not root or not root.spellRows then return end
    local rows = self.currentSpellRows or {}
    local maximum = math.max(0, #rows - SPELL_VISIBLE_ROWS)
    self.spellbookOffset = math.max(0, math.min(maximum, tonumber(self.spellbookOffset) or 0))
    root.spellMaxOffset = maximum
    if root.spellSlider then
        root.updatingSpellSlider = true
        root.spellSlider:SetMinMaxValues(0, maximum)
        root.spellSlider:SetValue(self.spellbookOffset)
        root.updatingSpellSlider = false
        if maximum > 0 then root.spellSlider:Show() else root.spellSlider:Hide() end
    end
    for index = 1, SPELL_VISIBLE_ROWS do
        local row = root.spellRows[index]
        local entry = rows[self.spellbookOffset + index]
        if entry then
            row.spellId = entry.spellId; row.spellName = entry.name; row.spellIcon = entry.icon
            row.icon:SetTexture(entry.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            row.nameText:SetText(entry.name or ("Spell " .. tostring(entry.spellId)))
            row.rankText:SetText(trim(entry.rank) ~= "" and tostring(entry.rank) or "Known spell")
            local autoText, r, g, b, description = spellAutoPresentation(self.selectedBot, entry.spellId)
            row.autoButton.spellId = entry.spellId; row.autoButton.spellName = entry.name; row.autoButton.autoDescription = description
            row.autoButton.label:SetText(autoText)
            setButtonEnabled(row.autoButton, self:IsSelectedBotOnline() and not (self.spellMutationPending and self.spellMutationPending[entry.spellId]))
            row.autoButton.label:SetTextColor(r, g, b)
            row:Show()
        else
            row.spellId = nil; row.spellName = nil; row.spellIcon = nil
            row.autoButton.spellId = nil; row.autoButton.spellName = nil; row.autoButton.autoDescription = nil
            row:Hide()
        end
    end
end

function BotInspect:RenderSpellbook()
    local root = self.frame and self.frame.spellbookView
    if not root then return end
    if not self.selectedBot then
        root.sourceText:SetText("Select a bot from the roster.")
        root.spellSummary:SetText("0 spells")
        self.currentSpellRows = {}
        self:RenderSpellbookRows()
        return
    end

    local spellbook, _, spellSource = self:GetDisplayDomain("BOT.SPELLBOOK")
    spellbook = type(spellbook) == "table" and spellbook or nil
    local ruleState = ignoredStateFor(self.selectedBot)
    local ruleText = "rules unknown"
    if ruleState and ruleState.status == "PENDING" then ruleText = "checking ignored spells..."
    elseif ruleState and ruleState.status == "READY" then ruleText = tostring(ruleState.ignoredCount or 0) .. " disabled"
    elseif ruleState and ruleState.status == "TIMEOUT" then ruleText = "ignored-list timeout" end
    root.sourceText:SetText("Spellbook: " .. statusTextForSource(spellSource) .. " · " .. ruleText)

    local query = root.spellSearch and root.spellSearch:GetText() or ""
    self.currentSpellRows = buildSpellRows(spellbook, query)
    local known = type(spellbook) == "table" and #(spellbook.spellIds or {}) or 0
    root.spellSummary:SetText(tostring(#self.currentSpellRows) .. "/" .. tostring(known))
    self:RenderSpellbookRows()
end


-- Narrow feature-coverage query for Playerbots' existing ignored-spell readback.
-- This is intentionally demand-driven: only Spellbook entry / selected-bot changes call ss ?.
local spellChatFrame = CreateFrame("Frame")
spellChatFrame:RegisterEvent("CHAT_MSG_WHISPER")
spellChatFrame:SetScript("OnEvent", function(_, event, message, author)
    if event == "CHAT_MSG_WHISPER" then BotInspect:HandleSpellIgnoredReply(message, author) end
end)
BotInspect.spellChatFrame = spellChatFrame

if type(ChatFrame_AddMessageEventFilter) == "function" then
    ChatFrame_AddMessageEventFilter("CHAT_MSG_WHISPER", function(_, _, message, author, ...)
        local key = normalizeBotName(author)
        local pending = BotInspect.spellIgnoredPending and BotInspect.spellIgnoredPending[key] or nil
        if pending and pending.status == "PENDING" and string.find(tostring(message or ""), "Ignored ", 1, true) then
            return true, message, author, ...
        end
        return false, message, author, ...
    end)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_WHISPER_INFORM", function(_, _, message, author, ...)
        local key = normalizeBotName(author)
        local pending = BotInspect.spellIgnoredPending and BotInspect.spellIgnoredPending[key] or nil
        if pending and pending.status == "PENDING" and trim(message) == "ss ?" then
            return true, message, author, ...
        end
        return false, message, author, ...
    end)
end
