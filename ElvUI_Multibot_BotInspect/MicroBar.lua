local addonName = ...
local BotInspect = _G.ElvUI_Multibot_BotInspect
if not BotInspect then return end

local E = BotInspect.E
local BUTTON_NAME = "ElvUI_Multibot_BotInspectMicroButton"
local EXTENDED_CAPACITY = 11
local MIGRATION_VERSION = 2

-- Exact ElvUI-WotLK 6.09 private MicroBar.lua order (release commit 8c0ac9d).
-- ElvUI keeps this table local, so it is intentionally mirrored here instead
-- of reading Blizzard's unrelated/global MICRO_BUTTONS table.
local ELVUI_609_MICRO_BUTTONS = {
    "CharacterMicroButton",
    "SpellbookMicroButton",
    "TalentMicroButton",
    "AchievementMicroButton",
    "QuestLogMicroButton",
    "SocialsMicroButton",
    "PVPMicroButton",
    "LFDMicroButton",
    "MainMenuMicroButton",
    "HelpMicroButton",
}

local function getActionBars()
    if not E or type(E.GetModule) ~= "function" then return nil end
    local ok, module = pcall(E.GetModule, E, "ActionBars")
    if ok then return module end
    return nil
end

local function getMicroDB()
    if E and type(E.db) == "table" and type(E.db.actionbar) == "table" and type(E.db.actionbar.microbar) == "table" then
        return E.db.actionbar.microbar
    end
    local AB = getActionBars()
    return AB and AB.db and AB.db.microbar or nil
end

local function getStockCount()
    return #ELVUI_609_MICRO_BUTTONS
end

local function getStockButton(index)
    local name = ELVUI_609_MICRO_BUTTONS[index]
    return name and _G[name] or nil
end

local function microbarMouseEnter(button)
    local bar = _G.ElvUI_MicroBar
    local db = getMicroDB()
    if bar and db and db.mouseover and E and type(E.UIFrameFadeIn) == "function" then
        E:UIFrameFadeIn(bar, 0.2, bar:GetAlpha(), tonumber(db.alpha) or 1)
    end

    if _G.GameTooltip then
        GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
        GameTooltip:AddLine("BotInspect", 1, 1, 1)
        GameTooltip:AddLine("Inspect and manage Playerbots", 0.72, 0.74, 0.78, true)
        GameTooltip:AddLine("Left-click: Toggle BotInspect", 0.45, 0.80, 1.00, true)
        GameTooltip:Show()
    end
end

local function microbarMouseLeave()
    if _G.GameTooltip then GameTooltip:Hide() end

    local bar = _G.ElvUI_MicroBar
    local db = getMicroDB()
    if bar and db and db.mouseover and E and type(E.UIFrameFadeOut) == "function" then
        E:UIFrameFadeOut(bar, 0.2, bar:GetAlpha(), 0)
    end
end

function BotInspect:GetExtendedMicroBarCapacity()
    return EXTENDED_CAPACITY
end

function BotInspect:ExtendElvUIMicroBarOptionLimit()
    if not E or not E.Options or not E.Options.args then return false end

    -- Exact ElvUI 6.09 OptionsUI path created by BuildABConfig().
    local actionbar = E.Options.args.actionbar
    local microbar = actionbar and actionbar.args and actionbar.args.microbar
    local option = microbar and microbar.args and microbar.args.buttonsPerRow
    if type(option) ~= "table" then return false end

    option.max = EXTENDED_CAPACITY
    return true
end

function BotInspect:MigrateMicroBarCapacityOnce()
    local settings = self:GetSettings()
    local currentVersion = tonumber(settings.microbarCapacityMigrationVersion) or 0
    if currentVersion >= MIGRATION_VERSION then return false end

    local db = getMicroDB()
    if db and settings.showMicroBarButton ~= false then
        local current = math.floor(tonumber(db.buttonsPerRow) or getStockCount())
        -- Alpha2.3/2.4 could mark the old migration as complete while failing to
        -- discover ElvUI's private button table. Use a new versioned migration
        -- so existing affected profiles get one clean 10 -> 11 correction.
        if current == getStockCount() then
            db.buttonsPerRow = EXTENDED_CAPACITY
        end
    end

    settings.microbarCapacityMigrationVersion = MIGRATION_VERSION
    settings.microbarCapacityMigrated = true -- retain backward compatibility
    return true
end

function BotInspect:CreateMicroBarButton()
    local bar = _G.ElvUI_MicroBar
    if not bar then return nil end

    local button = _G[BUTTON_NAME]
    if button then
        if button:GetParent() ~= bar then button:SetParent(bar) end
        button:SetFrameLevel((bar:GetFrameLevel() or 0) + 2)
        self.microBarButton = button
        return button
    end

    button = CreateFrame("Button", BUTTON_NAME, bar)
    button:SetFrameLevel((bar:GetFrameLevel() or 0) + 2)
    button:RegisterForClicks("LeftButtonUp")
    button:SetScript("OnClick", function() BotInspect:Toggle() end)
    button:SetScript("OnEnter", microbarMouseEnter)
    button:SetScript("OnLeave", microbarMouseLeave)

    local backdrop = CreateFrame("Frame", nil, button)
    backdrop:SetFrameLevel(math.max(1, button:GetFrameLevel() - 1))
    if type(backdrop.SetTemplate) == "function" then backdrop:SetTemplate("Default", true) end
    backdrop:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
    backdrop:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 0, 0)
    button.backdrop = backdrop

    local icon = backdrop:CreateTexture(nil, "ARTWORK")
    icon:SetTexture("Interface\\Icons\\INV_Misc_Spyglass_03")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    icon:SetPoint("TOPLEFT", backdrop, "TOPLEFT", 2, -2)
    icon:SetPoint("BOTTOMRIGHT", backdrop, "BOTTOMRIGHT", -2, 2)
    button.icon = icon

    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
    highlight:SetBlendMode("ADD")
    highlight:SetAllPoints(backdrop)
    button.highlight = highlight

    self.microBarButton = button
    return button
end

function BotInspect:UpdateMicroBarButtonLayout()
    local AB = getActionBars()
    local bar = _G.ElvUI_MicroBar
    if not AB or not bar then return false end

    local button = self:CreateMicroBarButton()
    if not button then return false end

    local settings = self:GetSettings()
    local db = getMicroDB()
    if settings.showMicroBarButton == false or not db or db.enabled == false then
        button:Hide()
        return true
    end

    local perRow = math.floor(tonumber(db.buttonsPerRow) or getStockCount())
    if perRow < 1 then perRow = 1 end
    if perRow > EXTENDED_CAPACITY then perRow = EXTENDED_CAPACITY end

    local reference = getStockButton(1)
    local previous = getStockButton(getStockCount())
    if not reference or not previous then
        button:Hide()
        return false
    end

    local size = tonumber(db.buttonSize) or tonumber(reference:GetWidth()) or 28
    local height = size * 1.4
    if type(button.Size) == "function" then button:Size(size, height) else button:SetWidth(size); button:SetHeight(height) end
    button:SetFrameLevel((bar:GetFrameLevel() or 0) + 2)
    button:ClearAllPoints()

    local offset = (E and type(E.Scale) == "function") and E:Scale(E.PixelMode and 1 or 3) or 3
    local spacingRaw = offset + (tonumber(db.buttonSpacing) or 0)
    local spacing = (E and type(E.Scale) == "function") and E:Scale(spacingRaw) or spacingRaw

    local index = EXTENDED_CAPACITY
    if (index - 1) % perRow == 0 then
        local above = getStockButton(index - perRow)
        if not above then
            button:Hide()
            return false
        end
        button:SetPoint("TOP", above, "BOTTOM", 0, -spacing)
    else
        button:SetPoint("LEFT", previous, "RIGHT", spacing, 0)
    end

    button:Show()

    -- Recompute geometry exactly like ElvUI 6.09, but for 11 total entries.
    -- This is idempotent: every ElvUI layout pass resets to stock first, then
    -- this post-hook writes the deterministic 11-entry dimensions.
    local rows = math.ceil(EXTENDED_CAPACITY / perRow)
    local width = (((reference:GetWidth() + spacing) * perRow) - spacing) + (offset * 2)
    local barHeight = (((reference:GetHeight() + spacing) * rows) - spacing) + (offset * 2)
    if type(bar.Size) == "function" then bar:Size(width, barHeight) else bar:SetWidth(width); bar:SetHeight(barHeight) end

    return true
end

function BotInspect:RefreshMicroBarButton()
    if not self.microBarHooked then return false end
    local AB = getActionBars()
    if AB and type(AB.UpdateMicroPositionDimensions) == "function" then
        AB:UpdateMicroPositionDimensions()
        return true
    end
    return false
end

function BotInspect:InitializeMicroBarIntegration()
    if self.microBarIntegrationInitialized then
        self:ExtendElvUIMicroBarOptionLimit()
        self:MigrateMicroBarCapacityOnce()
        self:RefreshMicroBarButton()
        return true
    end

    local AB = getActionBars()
    if not AB or type(AB.UpdateMicroPositionDimensions) ~= "function" or not _G.ElvUI_MicroBar then
        return false, "ELVUI_MICROBAR_UNAVAILABLE"
    end

    if type(hooksecurefunc) ~= "function" then
        return false, "HOOKSECUREFUNC_UNAVAILABLE"
    end

    self:MigrateMicroBarCapacityOnce()
    self:ExtendElvUIMicroBarOptionLimit()

    hooksecurefunc(AB, "UpdateMicroPositionDimensions", function()
        BotInspect:UpdateMicroBarButtonLayout()
    end)

    self.microBarHooked = true
    self.microBarIntegrationInitialized = true

    AB:UpdateMicroPositionDimensions()
    return true
end

-- Late-load safety: if BotInspect initialized before this source file became
-- available, complete integration once the file is parsed.
if BotInspect.initialized then
    BotInspect:InitializeMicroBarIntegration()
end
