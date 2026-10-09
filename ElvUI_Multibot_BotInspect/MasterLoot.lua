local addonName = ...
local BotInspect = _G.ElvUI_Multibot_BotInspect
if not BotInspect then return end

local API = BotInspect.api
local E = _G.ElvUI and _G.ElvUI[1]
local LootEnhance = {
    hooked = false,
    selectedLootSlot = nil,
    eventFrame = nil,
    originalDropDownInitialize = nil,
}
BotInspect.MasterLoot = LootEnhance

local function maxDropDownButtons()
    return tonumber(_G.UIDROPDOWNMENU_MAXBUTTONS) or 32
end
local CANDIDATE_MENU_WIDTH = 400
local CANDIDATE_BUTTON_WIDTH = CANDIDATE_MENU_WIDTH - 25
local CANDIDATE_META_WIDTH = 220
local ROOT_SELF_MENU_WIDTH = 220
local ROOT_SELF_BUTTON_WIDTH = ROOT_SELF_MENU_WIDTH - 25

local SLOT_LABELS = {
    [1] = "Head", [2] = "Neck", [3] = "Shoulder", [4] = "Shirt", [5] = "Chest",
    [6] = "Waist", [7] = "Legs", [8] = "Feet", [9] = "Wrist", [10] = "Hands",
    [11] = "Ring 1", [12] = "Ring 2", [13] = "Trinket 1", [14] = "Trinket 2",
    [15] = "Back", [16] = "Main Hand", [17] = "Off Hand", [18] = "Ranged", [19] = "Tabard",
}

local EQUIP_LOC_SLOTS = {
    INVTYPE_HEAD = { 1 }, INVTYPE_NECK = { 2 }, INVTYPE_SHOULDER = { 3 }, INVTYPE_BODY = { 4 },
    INVTYPE_CHEST = { 5 }, INVTYPE_ROBE = { 5 }, INVTYPE_WAIST = { 6 }, INVTYPE_LEGS = { 7 },
    INVTYPE_FEET = { 8 }, INVTYPE_WRIST = { 9 }, INVTYPE_HAND = { 10 },
    INVTYPE_FINGER = { 11, 12 }, INVTYPE_TRINKET = { 13, 14 }, INVTYPE_CLOAK = { 15 },
    INVTYPE_WEAPON = { 16, 17 }, INVTYPE_2HWEAPON = { 16 }, INVTYPE_WEAPONMAINHAND = { 16 },
    INVTYPE_WEAPONOFFHAND = { 17 }, INVTYPE_SHIELD = { 17 }, INVTYPE_HOLDABLE = { 17 },
    INVTYPE_RANGED = { 18 }, INVTYPE_RANGEDRIGHT = { 18 }, INVTYPE_THROWN = { 18 }, INVTYPE_RELIC = { 18 },
    INVTYPE_TABARD = { 19 },
}

local function normalizeName(value)
    value = tostring(value or "")
    value = string.gsub(value, "^%s+", "")
    value = string.gsub(value, "%s+$", "")
    value = string.gsub(value, "%-.*$", "")
    return string.lower(value)
end

local function getNormalText(button)
    if not button then return nil end
    local name = type(button.GetName) == "function" and button:GetName() or nil
    local region = name and _G[name .. "NormalText"] or nil
    if region then return region end
    if type(button.GetFontString) == "function" then return button:GetFontString() end
    return nil
end

local function classTokenForCandidate(candidate)
    local wanted = normalizeName(candidate)
    if wanted == "" then return nil end

    if type(GetNumRaidMembers) == "function" and (tonumber(GetNumRaidMembers()) or 0) > 0 and type(GetRaidRosterInfo) == "function" then
        for i = 1, GetNumRaidMembers() do
            local name, _, _, _, _, classToken = GetRaidRosterInfo(i)
            if normalizeName(name) == wanted then return classToken end
        end
    end

    if type(UnitName) == "function" and type(UnitClass) == "function" then
        if normalizeName(UnitName("player")) == wanted then
            local _, token = UnitClass("player")
            return token
        end
        local maximum = tonumber(_G.MAX_PARTY_MEMBERS) or 4
        for i = 1, maximum do
            local unit = "party" .. tostring(i)
            if normalizeName(UnitName(unit)) == wanted then
                local _, token = UnitClass(unit)
                return token
            end
        end
    end
    return nil
end

local function classColor(classToken)
    local colors = _G.CUSTOM_CLASS_COLORS or _G.RAID_CLASS_COLORS
    local color = colors and classToken and colors[classToken] or nil
    if color then return color.r or 1, color.g or 1, color.b or 1 end
    return 1, 0.82, 0
end


local function playerCandidate()
    if type(UnitName) ~= "function" or type(GetMasterLootCandidate) ~= "function" then return nil, nil end
    local playerName = UnitName("player")
    local wanted = normalizeName(playerName)
    if wanted == "" then return nil, nil end

    local maximum = 40
    if type(GetNumRaidMembers) == "function" and (tonumber(GetNumRaidMembers()) or 0) <= 0 then
        maximum = (tonumber(_G.MAX_PARTY_MEMBERS) or 4) + 1
    end
    for i = 1, maximum do
        local candidate = GetMasterLootCandidate(i)
        if candidate and normalizeName(candidate) == wanted then
            return i, candidate
        end
    end
    return nil, nil
end

local function visualRowPoint(button, row)
    if not button or not button:GetParent() then return end
    local xPos = 15
    local yPos = -(((tonumber(row) or 1) - 1) * (tonumber(_G.UIDROPDOWNMENU_BUTTON_HEIGHT) or 16))
        - (tonumber(_G.UIDROPDOWNMENU_BORDER_HEIGHT) or 15)
    button:ClearAllPoints()
    button:SetPoint("TOPLEFT", button:GetParent(), "TOPLEFT", xPos, yPos)
end

local function signedDelta(value)
    value = tonumber(value)
    if not value or value == 0 then return "±0" end
    if value > 0 then return "+" .. tostring(value) end
    return tostring(value)
end

local function knownBot(candidate)
    if not API then return false end
    if type(API.GetManagedBot) == "function" and API:GetManagedBot(candidate) then return true end
    if type(API.GetBot) == "function" and API:GetBot(candidate) then return true end
    return false
end

local function currentLootSlot()
    local selected = tonumber(LootEnhance.selectedLootSlot)
    if selected then return selected end

    -- ElvUI 6.09's custom ElvLootSlot OnClick still mirrors the chosen slot
    -- into Blizzard's LootFrame.selectedSlot before LootSlot() opens the ML menu.
    local lootFrame = _G.LootFrame
    selected = lootFrame and tonumber(lootFrame.selectedSlot) or nil
    return selected
end

local function currentLootLink()
    local slot = currentLootSlot()
    if not slot or type(GetLootSlotLink) ~= "function" then return nil end
    local ok, link = pcall(GetLootSlotLink, slot)
    if ok then return link end
    return nil
end

local function equipLocation(itemLink)
    if not itemLink or type(GetItemInfo) ~= "function" then return nil, nil end
    local ok, _, _, _, itemLevel, _, _, _, _, equipLoc = pcall(GetItemInfo, itemLink)
    if not ok then return nil, nil end
    return equipLoc, tonumber(itemLevel)
end

local function itemLevel(itemLink)
    if not itemLink or type(GetItemInfo) ~= "function" then return nil end
    local ok, _, _, _, level = pcall(GetItemInfo, itemLink)
    if ok then return tonumber(level) end
    return nil
end

local function comparisonTooltip(index)
    index = tonumber(index) or 1
    local name = "ElvUI_Multibot_BotInspectEquippedCompare" .. tostring(index)
    local tooltip = _G[name]
    if tooltip then return tooltip end
    if type(CreateFrame) ~= "function" or not UIParent then return nil end
    tooltip = CreateFrame("GameTooltip", name, UIParent, "GameTooltipTemplate")
    tooltip:SetOwner(UIParent, "ANCHOR_NONE")
    if type(tooltip.SetClampedToScreen) == "function" then tooltip:SetClampedToScreen(true) end
    tooltip:Hide()
    return tooltip
end

local function hideComparisonTooltips()
    for i = 1, 2 do
        local tooltip = _G["ElvUI_Multibot_BotInspectEquippedCompare" .. tostring(i)]
        if tooltip then tooltip:Hide() end
    end
end

local function tooltipSideForButton(button)
    if not button or type(button.GetCenter) ~= "function" or not UIParent or type(UIParent.GetCenter) ~= "function" then
        return false
    end
    local bx = button:GetCenter()
    local ux = UIParent:GetCenter()
    return bx and ux and bx > ux or false
end

local function setItemTooltip(tooltip, itemLink)
    if not tooltip or not itemLink or type(tooltip.SetHyperlink) ~= "function" then return false end
    tooltip:ClearLines()
    local ok = pcall(tooltip.SetHyperlink, tooltip, itemLink)
    if not ok then
        tooltip:ClearLines()
        tooltip:AddLine(tostring(itemLink), 1, 1, 1, true)
    end
    return true
end

local function anchorEquippedTooltip(tooltip, previous, placeLeft)
    if not tooltip then return end
    tooltip:ClearAllPoints()
    if previous then
        if placeLeft then
            tooltip:SetPoint("TOPRIGHT", previous, "BOTTOMRIGHT", 0, -4)
        else
            tooltip:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -4)
        end
    elseif placeLeft then
        tooltip:SetPoint("TOPRIGHT", GameTooltip, "TOPLEFT", -6, 0)
    else
        tooltip:SetPoint("TOPLEFT", GameTooltip, "TOPRIGHT", 6, 0)
    end
end

local function slotMap(equipment)
    local map = {}
    for _, slot in ipairs(type(equipment) == "table" and equipment.slots or {}) do
        if type(slot) == "table" and tonumber(slot.uiSlot) then map[tonumber(slot.uiSlot)] = slot end
    end
    return map
end

function LootEnhance:IsEnabled()
    local db = type(BotInspect.GetSettings) == "function" and BotInspect:GetSettings() or nil
    return not db or db.masterLootEnhancements ~= false
end

function LootEnhance:IsElvLootActive()
    return E and E.private and E.private.general and E.private.general.loot and _G.ElvLootFrame ~= nil
end

function LootEnhance:GetBotEquipment(candidate)
    if not knownBot(candidate) then return nil, nil, false end
    local equipment, meta
    if type(BotInspect.IsBotOnline) == "function" and BotInspect:IsBotOnline(candidate) and type(API.GetEquipmentView) == "function" then
        equipment, meta = API:GetEquipmentView(candidate)
        if equipment then return equipment, meta, false end
    end
    if type(API.GetLastKnown) == "function" then
        equipment, meta = API:GetLastKnown("BOT.EQUIPMENT", candidate)
        if equipment then return equipment, meta, true end
    end
    return nil, meta, false
end

function LootEnhance:ShowCandidateTooltip(button)
    hideComparisonTooltips()

    local candidate = button and button.botInspectLootCandidate
    if not candidate or not knownBot(candidate) or not _G.GameTooltip then return end

    local lootLink = currentLootLink()
    local equipLoc, lootLevel = equipLocation(lootLink)
    local placeLeft = tooltipSideForButton(button)
    GameTooltip:SetOwner(button, placeLeft and "ANCHOR_LEFT" or "ANCHOR_RIGHT")
    GameTooltip:ClearLines()

    if not lootLink then
        local classToken = classTokenForCandidate(candidate)
        local r, g, b = classColor(classToken)
        GameTooltip:AddLine(candidate, r, g, b)
        GameTooltip:AddLine("Loot item unavailable", 0.65, 0.67, 0.70)
        GameTooltip:Show()
        return
    end

    -- Render the loot item as a real Blizzard item tooltip. Do not reconstruct
    -- or filter its stats: the native tooltip is the comparison source.
    setItemTooltip(GameTooltip, lootLink)

    local classToken = classTokenForCandidate(candidate)
    local r, g, b = classColor(classToken)
    local spec, role, score = "--", "--", nil
    if type(BotInspect.GetBotDisplayProfile) == "function" then
        spec, role, score = BotInspect:GetBotDisplayProfile(candidate)
    end
    local profile = tostring(spec or "--") .. " · " .. tostring(role or "--")
    if score then profile = profile .. " · GS " .. tostring(math.floor(tonumber(score) or 0)) end

    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("LOOT → " .. tostring(candidate), r, g, b)
    GameTooltip:AddLine(profile, 0.72, 0.76, 0.82)

    local slots = equipLoc and EQUIP_LOC_SLOTS[equipLoc] or nil
    if not slots then
        GameTooltip:AddLine("No equippable comparison slot", 0.55, 0.58, 0.62)
        GameTooltip:Show()
        return
    end

    local equipment, _, historical = self:GetBotEquipment(candidate)
    if not equipment then
        GameTooltip:AddLine("Equipment not observed yet", 0.65, 0.67, 0.70)
        GameTooltip:Show()
        return
    end

    local map = slotMap(equipment)
    local shown = 0
    local previous = nil
    for _, uiSlot in ipairs(slots) do
        local current = map[uiSlot]
        if current and current.itemLink then
            shown = shown + 1
            local tooltip = comparisonTooltip(shown)
            if tooltip then
                tooltip:SetOwner(UIParent, "ANCHOR_NONE")
                setItemTooltip(tooltip, current.itemLink)

                local label = SLOT_LABELS[uiSlot] or ("Slot " .. tostring(uiSlot))
                local level = itemLevel(current.itemLink)
                local status = "CURRENTLY EQUIPPED · " .. label
                if historical then status = "LAST OBSERVED · " .. label end
                tooltip:AddLine(" ")
                tooltip:AddLine(status, historical and 0.95 or 0.35, historical and 0.72 or 0.95, historical and 0.30 or 0.55)
                tooltip:AddLine(tostring(candidate), r, g, b)
                if level and lootLevel then
                    tooltip:AddDoubleLine("Item level " .. tostring(level), "Loot Δ " .. signedDelta(lootLevel - level), 0.72, 0.76, 0.82, 0.72, 0.76, 0.82)
                elseif level then
                    tooltip:AddLine("Item level " .. tostring(level), 0.72, 0.76, 0.82)
                end

                anchorEquippedTooltip(tooltip, previous, placeLeft)
                tooltip:Show()
                previous = tooltip
            end
        end
    end

    if shown == 0 then
        GameTooltip:AddLine("Matching equipment slot is empty", 0.65, 0.67, 0.70)
    else
        GameTooltip:AddLine("Equipped item shown beside this tooltip", 0.35, 0.95, 0.55)
    end
    GameTooltip:Show()
end

function LootEnhance:ClearButton(button)
    hideComparisonTooltips()
    if not button then return end
    button.botInspectLootCandidate = nil
    button.botInspectLootCandidateIndex = nil
    button.botInspectQuickSelf = nil

    local native = getNormalText(button)
    if native and button.botInspectLootOriginalColor then
        native:SetTextColor(unpack(button.botInspectLootOriginalColor))
        button.botInspectLootOriginalColor = nil
    end
    if native and button.botInspectLootOriginalAlpha ~= nil then
        native:SetAlpha(button.botInspectLootOriginalAlpha)
        button.botInspectLootOriginalAlpha = nil
    end
    if button.botInspectLootMeta then button.botInspectLootMeta:Hide() end
    if button.botInspectQuickSelfLabel then button.botInspectQuickSelfLabel:Hide() end
    if button.botInspectQuickSelfName then button.botInspectQuickSelfName:Hide() end
    if button.botInspectLootOriginalWidth and type(button.SetWidth) == "function" then
        button:SetWidth(button.botInspectLootOriginalWidth)
        button.botInspectLootOriginalWidth = nil
    end
end

function LootEnhance:EnsureButtonDecorator(button)
    if button.botInspectLootMeta then return end

    local meta = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    meta:SetPoint("RIGHT", button, "RIGHT", -10, 0)
    meta:SetJustifyH("RIGHT")
    meta:SetWidth(CANDIDATE_META_WIDTH)
    meta:SetTextColor(0.64, 0.68, 0.74)
    meta:Hide()
    button.botInspectLootMeta = meta

    if E and E.media and E.media.normFont and type(meta.SetFont) == "function" then
        pcall(meta.SetFont, meta, E.media.normFont, 10, "OUTLINE")
    end

    if type(button.HookScript) == "function" and not button.botInspectLootHooks then
        button:HookScript("OnEnter", function(self)
            if self.botInspectLootCandidate then BotInspect.MasterLoot:ShowCandidateTooltip(self) end
        end)
        button:HookScript("OnLeave", function(self)
            if self.botInspectLootCandidate and _G.GameTooltip then GameTooltip:Hide() end
            hideComparisonTooltips()
        end)
        button:HookScript("OnHide", function(self)
            if BotInspect.MasterLoot then BotInspect.MasterLoot:ClearButton(self) end
        end)
        button.botInspectLootHooks = true
    end
end

function LootEnhance:EnsureQuickSelfDecorator(button)
    if button.botInspectQuickSelfLabel then return end

    local label = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("LEFT", button, "LEFT", 0, 0)
    label:SetWidth(100)
    label:SetJustifyH("LEFT")
    label:SetText("Send to self")
    label:Hide()
    button.botInspectQuickSelfLabel = label

    local name = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    name:SetPoint("RIGHT", button, "RIGHT", -10, 0)
    name:SetWidth(100)
    name:SetJustifyH("RIGHT")
    name:Hide()
    button.botInspectQuickSelfName = name

    if E and E.media and E.media.normFont then
        if type(label.SetFont) == "function" then pcall(label.SetFont, label, E.media.normFont, 10, "OUTLINE") end
        if type(name.SetFont) == "function" then pcall(name.SetFont, name, E.media.normFont, 10, "OUTLINE") end
    end
end

function LootEnhance:DecorateCandidate(button, candidate, candidateIndex)
    local native = getNormalText(button)
    if not native then return end
    self:EnsureButtonDecorator(button)

    button.botInspectLootCandidate = candidate
    button.botInspectLootCandidateIndex = candidateIndex

    if type(native.GetTextColor) == "function" and not button.botInspectLootOriginalColor then
        local r, g, b, a = native:GetTextColor()
        button.botInspectLootOriginalColor = { r or 1, g or 1, b or 1, a or 1 }
    end

    local classToken = classTokenForCandidate(candidate)
    local r, g, b = classColor(classToken)
    native:SetTextColor(r, g, b)

    if knownBot(candidate) and button.botInspectLootMeta then
        local spec, role, score = "--", "--", nil
        if type(BotInspect.GetBotDisplayProfile) == "function" then
            spec, role, score = BotInspect:GetBotDisplayProfile(candidate)
        end
        local text = tostring(spec or "--") .. " · " .. tostring(role or "--")
        if score then text = text .. " · GS " .. tostring(math.floor(tonumber(score) or 0)) end
        button.botInspectLootMeta:SetText(text)
        button.botInspectLootMeta:Show()
    elseif button.botInspectLootMeta then
        button.botInspectLootMeta:SetText("")
        button.botInspectLootMeta:Hide()
    end
end

function LootEnhance:ClearList(level)
    level = tonumber(level) or 1
    for i = 1, maxDropDownButtons() do
        local button = _G["DropDownList" .. tostring(level) .. "Button" .. tostring(i)]
        if button then self:ClearButton(button) end
    end
end

function LootEnhance:AddQuickSelfRow()
    if (tonumber(_G.UIDROPDOWNMENU_MENU_LEVEL) or 1) ~= 1 then return end
    if type(GetNumRaidMembers) ~= "function" or (tonumber(GetNumRaidMembers()) or 0) <= 0 then return end
    if type(UIDropDownMenu_AddButton) ~= "function" or type(_G.GroupLootDropDown_GiveLoot) ~= "function" then return end

    local candidateIndex, candidate = playerCandidate()
    if not candidateIndex or not candidate then return end

    local list = _G.DropDownList1
    if not list then return end

    local info = UIDropDownMenu_CreateInfo()
    -- Keep the native text as the exact candidate name because ElvUI 6.09's
    -- GroupLootDropDown_GiveLoot reads self:GetText() for confirmation text.
    -- The visible "Send to self" label is an overlay only.
    info.text = candidate
    info.fontObject = _G.GameFontNormalLeft
    info.value = candidateIndex
    info.notCheckable = 1
    info.func = _G.GroupLootDropDown_GiveLoot
    UIDropDownMenu_AddButton(info, 1)

    local selfButton = _G["DropDownList1Button" .. tostring(list.numButtons or 0)]
    if not selfButton then return end

    self:EnsureQuickSelfDecorator(selfButton)
    selfButton.botInspectQuickSelf = true

    local native = getNormalText(selfButton)
    if native then
        if selfButton.botInspectLootOriginalAlpha == nil and type(native.GetAlpha) == "function" then
            selfButton.botInspectLootOriginalAlpha = native:GetAlpha()
        end
        native:SetAlpha(0)
    end

    local classToken = classTokenForCandidate(candidate)
    local r, g, b = classColor(classToken)
    selfButton.botInspectQuickSelfLabel:SetTextColor(0.35, 0.95, 0.55)
    selfButton.botInspectQuickSelfLabel:SetText("Send to self")
    selfButton.botInspectQuickSelfLabel:Show()
    selfButton.botInspectQuickSelfName:SetText(candidate)
    selfButton.botInspectQuickSelfName:SetTextColor(r, g, b)
    selfButton.botInspectQuickSelfName:Show()

    -- Original raid root layout is: title, Group 1..N. The quick-self entry
    -- was appended by UIDropDownMenu_AddButton; move it visually to row 2 and
    -- push the existing groups down one row. Button values/functions remain
    -- native, so the group submenus are unaffected.
    local last = tonumber(list.numButtons) or 0
    if last >= 3 then
        for i = 2, last - 1 do
            local groupButton = _G["DropDownList1Button" .. tostring(i)]
            if groupButton then visualRowPoint(groupButton, i + 1) end
        end
        visualRowPoint(selfButton, 2)
    end

    list.maxWidth = math.max(tonumber(list.maxWidth) or 0, ROOT_SELF_BUTTON_WIDTH)
    selfButton:SetWidth(ROOT_SELF_BUTTON_WIDTH)
    list:SetWidth(ROOT_SELF_MENU_WIDTH)
    if type(list.HookScript) == "function" and not list.botInspectLootRootHideHook then
        list:HookScript("OnHide", function()
            if BotInspect.MasterLoot then BotInspect.MasterLoot:ClearList(1) end
        end)
        list.botInspectLootRootHideHook = true
    end
end

function LootEnhance:DecorateCurrentMenu()
    if not self:IsEnabled() or type(GetMasterLootCandidate) ~= "function" then return end

    local level = tonumber(_G.UIDROPDOWNMENU_MENU_LEVEL) or 1
    local list = _G["DropDownList" .. tostring(level)]
    if not list then return end

    self:ClearList(level)

    if level == 1 then
        self:AddQuickSelfRow()
        return
    end

    local found = false
    for i = 1, maxDropDownButtons() do
        local button = _G["DropDownList" .. tostring(level) .. "Button" .. tostring(i)]
        if button and button:IsShown() then
            local candidateIndex = tonumber(button.value)
            local candidate = candidateIndex and GetMasterLootCandidate(candidateIndex) or nil
            local native = getNormalText(button)
            local currentText = native and native:GetText() or nil
            if candidate and normalizeName(candidate) == normalizeName(currentText) then
                found = true
                self:DecorateCandidate(button, candidate, candidateIndex)
                if type(button.GetWidth) == "function" and type(button.SetWidth) == "function" then
                    button.botInspectLootOriginalWidth = button.botInspectLootOriginalWidth or button:GetWidth()
                    button:SetWidth(CANDIDATE_BUTTON_WIDTH)
                end
            end
        end
    end

    if found then
        -- Critical 3.3.5 detail: DropDownList OnShow recalculates width from
        -- list.maxWidth after this initializer returns. Set maxWidth too,
        -- otherwise the backdrop shrinks to the native name width while our
        -- spec/role/GS overlay remains outside it.
        list.maxWidth = math.max(tonumber(list.maxWidth) or 0, CANDIDATE_BUTTON_WIDTH)
        if type(list.SetWidth) == "function" then
            list:SetWidth(CANDIDATE_MENU_WIDTH)
        end

        if type(list.HookScript) == "function" and not list.botInspectLootHideHook then
            local hookedLevel = level
            list:HookScript("OnHide", function(self)
                if BotInspect.MasterLoot then BotInspect.MasterLoot:ClearList(hookedLevel) end
            end)
            list.botInspectLootHideHook = true
        end
    end
end

function LootEnhance:HookElvLootSlots()
    local frame = _G.ElvLootFrame
    if not frame or type(frame.slots) ~= "table" then return end

    for _, slotButton in pairs(frame.slots) do
        if slotButton and type(slotButton.HookScript) == "function" and not slotButton.botInspectMasterLootHook then
            slotButton:HookScript("OnClick", function(self)
                local slot = type(self.GetID) == "function" and tonumber(self:GetID()) or nil
                if slot then BotInspect.MasterLoot.selectedLootSlot = slot end
            end)
            slotButton.botInspectMasterLootHook = true
        end
    end
end

function LootEnhance:InstallElvLootTracking()
    if self.eventFrame then return end

    local frame = CreateFrame("Frame")
    frame:RegisterEvent("LOOT_OPENED")
    frame:RegisterEvent("LOOT_CLOSED")
    frame:RegisterEvent("OPEN_MASTER_LOOT_LIST")
    frame:SetScript("OnEvent", function(_, event)
        local self = BotInspect.MasterLoot
        if not self then return end

        if event == "LOOT_CLOSED" then
            self.selectedLootSlot = nil
            if _G.GameTooltip then GameTooltip:Hide() end
            hideComparisonTooltips()
            return
        end

        if self:IsElvLootActive() then
            if type(BotInspect.ScheduleLocal) == "function" and event == "LOOT_OPENED" then
                BotInspect:ScheduleLocal("master-loot-elvslots", 0.05, function()
                    if BotInspect.MasterLoot then BotInspect.MasterLoot:HookElvLootSlots() end
                end)
            else
                self:HookElvLootSlots()
            end
        end

        if event == "OPEN_MASTER_LOOT_LIST" and not self.selectedLootSlot then
            local lootFrame = _G.LootFrame
            self.selectedLootSlot = lootFrame and tonumber(lootFrame.selectedSlot) or nil
        end
    end)
    self.eventFrame = frame

    if self:IsElvLootActive() then self:HookElvLootSlots() end
end

function LootEnhance:InstallHooks()
    if self.hooked then return true end

    local dropDown = _G.GroupLootDropDown
    if not dropDown or type(dropDown.initialize) ~= "function" then return false end

    -- IMPORTANT (3.3.5a / ElvUI 6.09): GroupLootDropDown_OnLoad stores the
    -- initializer function object on GroupLootDropDown.initialize. Hooking the
    -- later global GroupLootDropDown_Initialize does NOT intercept dropdown
    -- rebuilds because UIDropDownMenu invokes the stored callback directly.
    -- Wrap that exact callback instead, preserving the native/ElvUI behavior.
    self.originalDropDownInitialize = dropDown.initialize
    dropDown.initialize = function(...)
        local original = BotInspect.MasterLoot and BotInspect.MasterLoot.originalDropDownInitialize
        if type(original) == "function" then original(...) end
        if BotInspect.MasterLoot then BotInspect.MasterLoot:DecorateCurrentMenu() end
    end

    self:InstallElvLootTracking()
    self.hooked = true
    return true
end

function BotInspect:InitializeMasterLootEnhancements()
    if self.MasterLoot and self.MasterLoot:InstallHooks() then return end
    if type(self.ScheduleLocal) == "function" then
        self:ScheduleLocal("master-loot-hook", 1.0, function()
            if BotInspect.MasterLoot then BotInspect.MasterLoot:InstallHooks() end
        end)
    end
end
