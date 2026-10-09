local addonName = ...
local BotInspect = _G.ElvUI_Multibot_BotInspect
if not BotInspect then return end

local HOTKEY_BUTTON_NAME = "ElvUI_Multibot_BotInspectHotkeyButton"

local function normalizeKey(key)
    if type(key) ~= "string" then return "" end
    key = string.upper(key)
    key = string.gsub(key, "%s+", "")
    return key
end

function BotInspect:GetHotkey()
    local db = self:GetSettings()
    return normalizeKey(db.hotkey or "SHIFT-C")
end

function BotInspect:IsHotkeyEnabled()
    return self:GetSettings().hotkeyEnabled ~= false
end

function BotInspect:CreateHotkeyBindingFrames()
    if self.hotkeyOwner and self.hotkeyButton then return true end
    if type(CreateFrame) ~= "function" then return false end

    self.hotkeyOwner = self.hotkeyOwner or CreateFrame("Frame", nil, UIParent)

    local button = _G[HOTKEY_BUTTON_NAME]
    if not button then
        button = CreateFrame("Button", HOTKEY_BUTTON_NAME, UIParent)
        button:SetWidth(1)
        button:SetHeight(1)
        button:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -20, 20)
        button:SetAlpha(0)
        button:RegisterForClicks("LeftButtonUp")
    end
    button:SetScript("OnClick", function()
        if BotInspect:IsHotkeyEnabled() then BotInspect:Toggle() end
    end)
    button:Show()
    self.hotkeyButton = button
    return true
end

function BotInspect:ApplyHotkeyBinding()
    if not self:CreateHotkeyBindingFrames() then return false, "BINDING_FRAME_UNAVAILABLE" end

    if type(InCombatLockdown) == "function" and InCombatLockdown() then
        self.hotkeyApplyPending = true
        return false, "COMBAT_DEFERRED"
    end

    if type(ClearOverrideBindings) ~= "function" or type(SetOverrideBindingClick) ~= "function" then
        return false, "OVERRIDE_BINDINGS_UNAVAILABLE"
    end

    ClearOverrideBindings(self.hotkeyOwner)
    self.hotkeyApplyPending = false
    self.hotkeyApplied = nil

    if not self:IsHotkeyEnabled() then return true end

    local key = self:GetHotkey()
    if key == "" then return true end

    local ok = pcall(SetOverrideBindingClick, self.hotkeyOwner, true, key, HOTKEY_BUTTON_NAME, "LeftButton")
    if not ok then return false, "BINDING_REJECTED" end
    self.hotkeyApplied = key
    return true
end

function BotInspect:RefreshHotkeyBinding()
    if not self.initialized then return end
    local ok, reason = self:ApplyHotkeyBinding()
    if not ok and reason == "COMBAT_DEFERRED" then
        -- PLAYER_REGEN_ENABLED below will apply the profile setting safely.
        return
    end
end

function BotInspect:SetHotkeyEnabled(value)
    self:GetSettings().hotkeyEnabled = value and true or false
    self:RefreshHotkeyBinding()
end

function BotInspect:SetHotkey(key)
    key = normalizeKey(key)
    self:GetSettings().hotkey = key
    self:RefreshHotkeyBinding()
end

function BotInspect:InitializeHotkeyIntegration()
    if self.hotkeyInitialized then
        self:RefreshHotkeyBinding()
        return true
    end
    if not self:CreateHotkeyBindingFrames() then return false end

    local eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    eventFrame:SetScript("OnEvent", function()
        if BotInspect.hotkeyApplyPending then BotInspect:ApplyHotkeyBinding() end
    end)
    self.hotkeyEventFrame = eventFrame
    self.hotkeyInitialized = true
    self:ApplyHotkeyBinding()
    return true
end
