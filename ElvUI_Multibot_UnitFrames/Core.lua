local ADDON_NAME = ...
local MODULE_NAME = "ElvUI_Multibot_UnitFrames"
local VERSION = "0.4.0-alpha1"

local ElvUI = _G.ElvUI
if not ElvUI then return end

local E, L, V, P, G = unpack(ElvUI)
local MBUF = E:NewModule("MultibotUnitFrames", "AceEvent-3.0", "AceTimer-3.0", "AceHook-3.0")

-- Runtime bindings are intentionally deferred to MBUF:Initialize(). This external
-- ElvUI plugin is started through LibElvUIPlugin:HookInitialize(), which runs after
-- ElvUI has established E.data/E.db; addon file-load completion is not readiness.
local ElvUF
local UF
local Core
local API

local pairs = pairs
local type = type
local tostring = tostring
local tonumber = tonumber
local format = string.format
local UnitExists = UnitExists
local UnitName = UnitName
local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown
local IsControlKeyDown = IsControlKeyDown
local WorldFrame = WorldFrame
local QUEST_LOG_MAX = tonumber(_G.MAX_QUESTLOG_QUESTS) or 25

local SUPPORTED_FRAME_TYPES = {
    party = true,
    raid = true,
    raid40 = true,
}

local DEFAULTS = {
    enabled = true,
    indicator = {
        enabled = true,
        text = "PB",
        fontSize = 10,
        anchor = "TOPRIGHT",
        x = -2,
        y = -2,
    },
    roleText = {
        enabled = true,
        fontSize = 9,
        anchor = "BOTTOMLEFT",
        x = 2,
        y = 2,
    },
    specText = {
        enabled = true,
        fontSize = 9,
        anchor = "BOTTOMRIGHT",
        x = -2,
        y = 2,
    },
    movementText = {
        enabled = true,
        fontSize = 9,
        anchor = "TOPLEFT",
        x = 2,
        y = -2,
    },
    xpText = {
        enabled = false,
        fontSize = 9,
        anchor = "LEFT",
        x = 2,
        y = 0,
    },
    inventoryText = {
        enabled = false,
        fontSize = 9,
        anchor = "RIGHT",
        x = -2,
        y = 0,
        mode = "PERCENT",
    },
    durabilityText = {
        enabled = false,
        fontSize = 9,
        anchor = "BOTTOM",
        x = 0,
        y = 2,
    },
    currencyText = {
        enabled = false,
        fontSize = 9,
        anchor = "TOP",
        x = 0,
        y = -2,
        showSilver = true,
        showCopper = true,
    },
    questText = {
        enabled = false,
        fontSize = 9,
        anchor = "BOTTOM",
        x = 0,
        y = 12,
        colorByCapacity = true,
    },
    selection = {
        clickEnabled = true,
        highlightEnabled = true,
        borderSize = 2,
        color = { r = 0.20, g = 0.80, b = 1.00, a = 1.00 },
    },
}

local VALID_ANCHORS = {
    TOPLEFT = true, TOP = true, TOPRIGHT = true,
    LEFT = true, CENTER = true, RIGHT = true,
    BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true,
}

local function ApplyDefaults(target, defaults)
    for key, value in pairs(defaults) do
        if type(value) == "table" then
            if type(target[key]) ~= "table" then target[key] = {} end
            ApplyDefaults(target[key], value)
        elseif target[key] == nil then
            target[key] = value
        end
    end
end

-- Register defaults with ElvUI's profile defaults. GetDB() also defensively
-- fills missing fields for legacy profiles or unusual load orders.
P.multibotUnitFrames = P.multibotUnitFrames or {}
ApplyDefaults(P.multibotUnitFrames, DEFAULTS)

MBUF.version = VERSION
MBUF.moduleName = MODULE_NAME
MBUF.api = nil
MBUF.enabled = false
MBUF.initialized = false
MBUF.coreRegistered = false
MBUF.profileCallbacksRegistered = false
MBUF.optionsRegistered = false
MBUF.lifecycleReady = false
MBUF.lastBootstrapReason = "not-run"
MBUF.bootstrapAttempts = 0
MBUF.pendingScan = false
MBUF.deferredRefreshTimer = nil
MBUF.subscriptions = {}
MBUF.trackedFrames = {}
MBUF.dataInterests = {}
MBUF.pendingDataTargets = {}
MBUF.dataRefreshTimer = nil
MBUF.elvUIHooked = false
MBUF.pendingSecureSelectionUpdate = false
MBUF.worldSelectionCatcher = nil
MBUF.stats = {
    scans = 0,
    eligibleFrames = 0,
    resolvedBotFrames = 0,
    shownIndicators = 0,
    shownRoleTexts = 0,
    shownSpecTexts = 0,
    shownMovementTexts = 0,
    shownXPTexts = 0,
    shownInventoryTexts = 0,
    shownDurabilityTexts = 0,
    shownCurrencyTexts = 0,
    shownQuestTexts = 0,
    interestedBots = 0,
    selectedBotFrames = 0,
    primarySelectionCount = 0,
}

local function Print(message)
    if E and E.Print then
        E:Print("|cff1784d1Multibot UnitFrames:|r " .. tostring(message))
    elseif DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("Multibot UnitFrames: " .. tostring(message))
    end
end

local function IsSupportedFrame(frame)
    if not frame then return false end
    local frameType = frame.unitframeType
    return frameType and SUPPORTED_FRAME_TYPES[frameType] == true
end

local function RegionIsVisible(region)
    if not region then return false end
    if region.IsVisible then return region:IsVisible() and true or false end
    return region:IsShown() and true or false
end

function MBUF:IsProfileDBReady()
    return type(E.db) == "table"
end

function MBUF:GetDB()
    -- Options may query before ElvUI has attached the active profile. Return
    -- immutable defaults for display only in that narrow window; runtime
    -- bootstrap never proceeds until the real profile table exists.
    if not self:IsProfileDBReady() then
        return DEFAULTS
    end

    if type(E.db.multibotUnitFrames) ~= "table" then
        E.db.multibotUnitFrames = {}
    end

    ApplyDefaults(E.db.multibotUnitFrames, DEFAULTS)
    return E.db.multibotUnitFrames
end

function MBUF:MigrateLegacyDB()
    if not self:IsProfileDBReady() then return false end

    local legacy = _G.ElvUI_Multibot_UnitFramesDB
    if type(legacy) ~= "table" or legacy._migratedToElvUIProfile == true then
        return false
    end

    local db = self:GetDB()
    if legacy.enabled ~= nil then db.enabled = legacy.enabled == true end

    if type(legacy.indicator) == "table" then
        local old = legacy.indicator
        local current = db.indicator
        if old.enabled ~= nil then current.enabled = old.enabled == true end
        if old.text ~= nil then current.text = tostring(old.text) end
        if old.fontSize ~= nil then current.fontSize = tonumber(old.fontSize) or current.fontSize end
        if old.anchor ~= nil then current.anchor = tostring(old.anchor) end
        if old.x ~= nil then current.x = tonumber(old.x) or current.x end
        if old.y ~= nil then current.y = tonumber(old.y) or current.y end
    end

    legacy._migratedToElvUIProfile = true
    return true
end

function MBUF:ResetSettings()
    if not self:IsProfileDBReady() then return end
    E.db.multibotUnitFrames = {}
    ApplyDefaults(E.db.multibotUnitFrames, DEFAULTS)

    if E.db.multibotUnitFrames.enabled == true and not self.enabled then
        self:EnableModule()
    elseif E.db.multibotUnitFrames.enabled ~= true and self.enabled then
        self:DisableModule()
    end

    self:ApplyPresentationSettings()
end

function MBUF:GetUnitBot(frame)
    if not frame or not frame.unit or not UnitExists(frame.unit) then return nil end

    local name = UnitName(frame.unit)
    if not name then return nil end

    local bot = API:GetBot(name)
    if bot and bot.online == true then return bot end
    return nil
end

function MBUF:GetIndicatorHost(frame)
    -- ElvUI 6.09 builds normal UnitFrame text/icons on RaisedElementParent.
    -- Using the same host keeps PB above health/power/portrait layers and avoids
    -- a frame-level race during PLAYER_ENTERING_WORLD / profile refreshes.
    if frame and frame.RaisedElementParent and frame.RaisedElementParent.CreateFontString then
        return frame.RaisedElementParent, "RaisedElementParent"
    end
    return frame, "frame-fallback"
end

function MBUF:UpdateIndicatorLayout(frame)
    if not frame or not frame.MultibotIndicator then return end

    local db = self:GetDB()
    local indicatorDB = db.indicator
    local indicator = frame.MultibotIndicator

    -- Fallback overlays need their level reasserted after ElvUI changes frame levels.
    if frame.MultibotOverlay and frame.GetFrameLevel and frame.MultibotOverlay.SetFrameLevel then
        frame.MultibotOverlay:SetFrameLevel((frame:GetFrameLevel() or 0) + 100)
    end

    local font = (E.media and E.media.normFont) or STANDARD_TEXT_FONT
    indicator:SetFont(font, tonumber(indicatorDB.fontSize) or 10, "OUTLINE")

    local anchor = tostring(indicatorDB.anchor or "TOPRIGHT")
    if not VALID_ANCHORS[anchor] then anchor = "TOPRIGHT" end

    if anchor:find("LEFT", 1, true) then
        indicator:SetJustifyH("LEFT")
    elseif anchor:find("RIGHT", 1, true) then
        indicator:SetJustifyH("RIGHT")
    else
        indicator:SetJustifyH("CENTER")
    end

    if anchor:find("TOP", 1, true) then
        indicator:SetJustifyV("TOP")
    elseif anchor:find("BOTTOM", 1, true) then
        indicator:SetJustifyV("BOTTOM")
    else
        indicator:SetJustifyV("MIDDLE")
    end

    indicator:ClearAllPoints()
    indicator:SetPoint(
        anchor,
        frame,
        anchor,
        tonumber(indicatorDB.x) or -2,
        tonumber(indicatorDB.y) or -2
    )
    indicator:SetText("|cff40ff40" .. tostring(indicatorDB.text or "PB") .. "|r")
end

local function ConfigureTextRegion(region, frame, settings, fallbackAnchor, fallbackSize, text)
    if not region or not frame then return end

    local font = (E.media and E.media.normFont) or STANDARD_TEXT_FONT
    region:SetFont(font, tonumber(settings.fontSize) or fallbackSize or 9, "OUTLINE")

    local anchor = tostring(settings.anchor or fallbackAnchor or "CENTER")
    if not VALID_ANCHORS[anchor] then anchor = fallbackAnchor or "CENTER" end

    if anchor:find("LEFT", 1, true) then
        region:SetJustifyH("LEFT")
    elseif anchor:find("RIGHT", 1, true) then
        region:SetJustifyH("RIGHT")
    else
        region:SetJustifyH("CENTER")
    end

    if anchor:find("TOP", 1, true) then
        region:SetJustifyV("TOP")
    elseif anchor:find("BOTTOM", 1, true) then
        region:SetJustifyV("BOTTOM")
    else
        region:SetJustifyV("MIDDLE")
    end

    region:ClearAllPoints()
    region:SetPoint(
        anchor,
        frame,
        anchor,
        tonumber(settings.x) or 0,
        tonumber(settings.y) or 0
    )
    region:SetText(tostring(text or ""))
end

function MBUF:GetPresentationHost(frame)
    if frame and frame.MultibotIndicatorHost and frame.MultibotIndicatorHost.CreateFontString then
        return frame.MultibotIndicatorHost
    end

    if frame and frame.RaisedElementParent and frame.RaisedElementParent.CreateFontString then
        return frame.RaisedElementParent
    end

    if frame and frame.MultibotOverlay and frame.MultibotOverlay.CreateFontString then
        return frame.MultibotOverlay
    end

    return frame
end

function MBUF:CreateInfoText(frame, fieldName)
    if not frame then return nil end
    if frame[fieldName] then return frame[fieldName] end

    -- CreateIndicator() establishes the validated ElvUI raised/fallback host.
    if not frame.MultibotIndicatorHost then
        self:CreateIndicator(frame)
    end

    local host = self:GetPresentationHost(frame)
    if not host or not host.CreateFontString then return nil end

    local region = host:CreateFontString(nil, "OVERLAY")
    region:Hide()
    frame[fieldName] = region
    return region
end

function MBUF:GetRoleDisplay(botRef)
    local role = API:GetBotRole(botRef)
    if not role or not role.primary then return "Unknown", "UNKNOWN" end
    local primary = tostring(role.primary)
    if primary == "UNKNOWN" then primary = "Unknown" end
    return primary, tostring(role.state or "UNKNOWN")
end

function MBUF:GetSpecDisplay(botRef)
    local spec = API:GetBotSpec(botRef)
    if not spec or not spec.primary then return "Unknown", "UNKNOWN" end
    local primary = tostring(spec.primary)
    if primary == "UNKNOWN" then primary = "Unknown" end
    if primary == "HYBRID" then primary = "Hybrid" end
    return primary, tostring(spec.state or "UNKNOWN")
end

local function StrategySet(list)
    local set = {}
    if type(list) ~= "table" then return set end
    for _, value in pairs(list) do
        local key = string.lower(tostring(value or ""))
        if key ~= "" then set[key] = true end
    end
    return set
end

function MBUF:GetMovementDisplay(botRef)
    local state = API:Get("BOT.STATE", botRef)
    if type(state) ~= "table" then return "Unknown", "UNKNOWN" end

    local normal = StrategySet(state.normalStrategies)
    local combat = StrategySet(state.combatStrategies)

    -- Current Playerbots flee changes both non-combat and combat to
    -- +follow,-stay,+passive. Require that full signature so ordinary follow
    -- plus an unrelated passive setting is not casually misreported as flee.
    if normal.follow and normal.passive and combat.follow and combat.passive then
        return "Fleeing", "CONFIRMED"
    end

    -- Stay is authoritative enough when present in either state. The normal
    -- stay shortcut installs it in both non-combat and combat, but accepting
    -- either side makes the display resilient while Core is refreshing.
    if normal.stay or combat.stay then
        return "Staying", "CONFIRMED"
    end

    -- Standard follow is represented by non-combat follow. In current
    -- Playerbots the combat shortcut deliberately removes follow, so requiring
    -- combat follow here would incorrectly hide the normal Following state.
    if normal.follow then
        return "Following", "CONFIRMED"
    end

    return "Unknown", "UNKNOWN"
end

local function ClampPercent(value)
    value = tonumber(value) or 0
    if value < 0 then value = 0 end
    if value > 100 then value = 100 end
    return math.floor(value + 0.5)
end

function MBUF:GetStatsSnapshot(botRef)
    local stats = API:Get("BOT.STATS", botRef)
    if type(stats) ~= "table" then return nil end
    return stats
end

function MBUF:GetXPDisplay(botRef)
    local stats = self:GetStatsSnapshot(botRef)
    if not stats then return "XP: Unknown" end
    return format("XP: %d%%", ClampPercent(stats.xpPct))
end

function MBUF:GetInventoryDisplay(botRef)
    local stats = self:GetStatsSnapshot(botRef)
    if not stats then return "Bag: Unknown" end

    local used = math.max(0, tonumber(stats.bagUsed) or 0)
    local total = math.max(0, tonumber(stats.bagTotal) or 0)
    local mode = tostring(self:GetDB().inventoryText.mode or "PERCENT")

    if mode == "USED_TOTAL" then
        return format("Bag: %d/%d", used, total)
    end

    if total <= 0 then return "Bag: 0%" end
    return format("Bag: %d%%", ClampPercent((used / total) * 100))
end

function MBUF:GetDurabilityDisplay(botRef)
    local stats = self:GetStatsSnapshot(botRef)
    if not stats then return "Dura: Unknown" end
    return format("Dura: %d%%", ClampPercent(stats.durabilityPct))
end

function MBUF:GetCurrencyDisplay(botRef)
    local stats = self:GetStatsSnapshot(botRef)
    if not stats then return "Unknown" end

    local db = self:GetDB().currencyText
    local parts = { format("%dg", math.max(0, tonumber(stats.gold) or 0)) }
    if db.showSilver == true then
        parts[#parts + 1] = format("%ds", math.max(0, tonumber(stats.silver) or 0))
    end
    if db.showCopper == true then
        parts[#parts + 1] = format("%dc", math.max(0, tonumber(stats.copper) or 0))
    end
    return table.concat(parts, " ")
end

function MBUF:GetQuestDisplay(botRef)
    local view = API:GetQuestView(botRef)
    if type(view) ~= "table" then
        return format("Quest: ?/%d", QUEST_LOG_MAX), nil, QUEST_LOG_MAX
    end

    local count = math.max(0, tonumber(view.totalCount) or 0)
    return format("Quest: %d/%d", count, QUEST_LOG_MAX), count, QUEST_LOG_MAX
end

function MBUF:GetQuestCapacityColor(count, maximum)
    count = tonumber(count)
    maximum = tonumber(maximum) or QUEST_LOG_MAX
    if not count or maximum <= 0 then return 1, 1, 1 end

    local ratio = count / maximum
    if ratio < 0 then ratio = 0 end
    if ratio > 1 then ratio = 1 end

    -- Smooth two-stage ramp: white -> yellow -> red.
    if ratio <= 0.5 then
        local t = ratio * 2
        return 1, 1, 1 - t
    end

    local t = (ratio - 0.5) * 2
    return 1, 1 - t, 0
end

function MBUF:UpdateInfoTexts(frame, bot)
    local db = self:GetDB()
    local roleRegion = self:CreateInfoText(frame, "MultibotRoleText")
    local specRegion = self:CreateInfoText(frame, "MultibotSpecText")
    local movementRegion = self:CreateInfoText(frame, "MultibotMovementText")
    local xpRegion = self:CreateInfoText(frame, "MultibotXPText")
    local inventoryRegion = self:CreateInfoText(frame, "MultibotInventoryText")
    local durabilityRegion = self:CreateInfoText(frame, "MultibotDurabilityText")
    local currencyRegion = self:CreateInfoText(frame, "MultibotCurrencyText")
    local questRegion = self:CreateInfoText(frame, "MultibotQuestText")

    local roleVisible, specVisible, movementVisible = false, false, false
    local xpVisible, inventoryVisible, durabilityVisible, currencyVisible, questVisible = false, false, false, false, false
    local botRef = bot and (bot.key or bot.name) or nil

    if bot and db.enabled == true and db.roleText.enabled == true and roleRegion then
        local roleValue = self:GetRoleDisplay(botRef)
        ConfigureTextRegion(roleRegion, frame, db.roleText, "BOTTOMLEFT", 9, roleValue)
        roleRegion:Show()
        roleVisible = RegionIsVisible(roleRegion)
    elseif roleRegion then
        roleRegion:Hide()
    end

    if bot and db.enabled == true and db.specText.enabled == true and specRegion then
        local specValue = self:GetSpecDisplay(botRef)
        ConfigureTextRegion(specRegion, frame, db.specText, "BOTTOMRIGHT", 9, specValue)
        specRegion:Show()
        specVisible = RegionIsVisible(specRegion)
    elseif specRegion then
        specRegion:Hide()
    end

    if bot and db.enabled == true and db.movementText.enabled == true and movementRegion then
        local movementValue = self:GetMovementDisplay(botRef)
        ConfigureTextRegion(movementRegion, frame, db.movementText, "TOPLEFT", 9, movementValue)
        movementRegion:Show()
        movementVisible = RegionIsVisible(movementRegion)
    elseif movementRegion then
        movementRegion:Hide()
    end

    if bot and db.enabled == true and db.xpText.enabled == true and xpRegion then
        ConfigureTextRegion(xpRegion, frame, db.xpText, "LEFT", 9, self:GetXPDisplay(botRef))
        xpRegion:Show()
        xpVisible = RegionIsVisible(xpRegion)
    elseif xpRegion then
        xpRegion:Hide()
    end

    if bot and db.enabled == true and db.inventoryText.enabled == true and inventoryRegion then
        ConfigureTextRegion(inventoryRegion, frame, db.inventoryText, "RIGHT", 9, self:GetInventoryDisplay(botRef))
        inventoryRegion:Show()
        inventoryVisible = RegionIsVisible(inventoryRegion)
    elseif inventoryRegion then
        inventoryRegion:Hide()
    end

    if bot and db.enabled == true and db.durabilityText.enabled == true and durabilityRegion then
        ConfigureTextRegion(durabilityRegion, frame, db.durabilityText, "BOTTOM", 9, self:GetDurabilityDisplay(botRef))
        durabilityRegion:Show()
        durabilityVisible = RegionIsVisible(durabilityRegion)
    elseif durabilityRegion then
        durabilityRegion:Hide()
    end

    if bot and db.enabled == true and db.currencyText.enabled == true and currencyRegion then
        ConfigureTextRegion(currencyRegion, frame, db.currencyText, "TOP", 9, self:GetCurrencyDisplay(botRef))
        currencyRegion:Show()
        currencyVisible = RegionIsVisible(currencyRegion)
    elseif currencyRegion then
        currencyRegion:Hide()
    end

    if bot and db.enabled == true and db.questText.enabled == true and questRegion then
        local questValue, questCount, questMaximum = self:GetQuestDisplay(botRef)
        ConfigureTextRegion(questRegion, frame, db.questText, "BOTTOM", 9, questValue)
        if db.questText.colorByCapacity == true then
            local r, g, b = self:GetQuestCapacityColor(questCount, questMaximum)
            questRegion:SetTextColor(r, g, b, 1)
        else
            questRegion:SetTextColor(1, 1, 1, 1)
        end
        questRegion:Show()
        questVisible = RegionIsVisible(questRegion)
    elseif questRegion then
        questRegion:Hide()
    end

    return roleVisible, specVisible, movementVisible, xpVisible, inventoryVisible, durabilityVisible, currencyVisible, questVisible
end

function MBUF:GetPrimarySelection()
    local selection = API:GetSelection("PRIMARY")
    if type(selection) ~= "table" then
        return { id = "PRIMARY", keys = {}, bots = {}, count = 0 }, {}
    end

    local selected = {}
    for _, key in ipairs(selection.keys or {}) do
        selected[tostring(key)] = true
    end
    return selection, selected
end

-- Ctrl+Left-click is reserved for Multibot selection. ElvUI/oUF unit frames
-- inherit SecureUnitButtonTemplate and normally resolve *type1 to "target".
-- A modifier-specific no-op action overrides that inherited target action while
-- preserving every unmodified click. Secure attributes may only be changed out
-- of combat, so changes requested during combat are deferred.
local SELECTION_NOOP_ACTION = "mbufnoop"

function MBUF:UpdateFrameSelectionClickBehavior(frame)
    if not frame or not IsSupportedFrame(frame) then return end
    if not frame.GetAttribute or not frame.SetAttribute then return end

    if InCombatLockdown and InCombatLockdown() then
        self.pendingSecureSelectionUpdate = true
        return
    end

    local db = self:GetDB()
    local shouldSuppress = self.enabled == true
        and db.enabled == true
        and db.selection
        and db.selection.clickEnabled == true

    if not frame.MultibotCtrlType1Captured then
        frame.MultibotOriginalCtrlType1 = frame:GetAttribute("ctrl-type1")
        frame.MultibotCtrlType1Captured = true
    end

    if shouldSuppress then
        if frame:GetAttribute("ctrl-type1") ~= SELECTION_NOOP_ACTION then
            frame:SetAttribute("ctrl-type1", SELECTION_NOOP_ACTION)
        end
        frame.MultibotCtrlTargetSuppressed = true
    elseif frame.MultibotCtrlTargetSuppressed then
        frame:SetAttribute("ctrl-type1", frame.MultibotOriginalCtrlType1)
        frame.MultibotCtrlTargetSuppressed = false
    end
end

function MBUF:UpdateAllSelectionClickBehavior()
    if InCombatLockdown and InCombatLockdown() then
        self.pendingSecureSelectionUpdate = true
        return
    end

    self.pendingSecureSelectionUpdate = false
    for frame in pairs(self.trackedFrames) do
        self:UpdateFrameSelectionClickBehavior(frame)
    end
end

function MBUF:RestoreSelectionClickBehavior()
    if InCombatLockdown and InCombatLockdown() then
        self.pendingSecureSelectionUpdate = true
        return
    end

    for frame in pairs(self.trackedFrames) do
        if frame and frame.MultibotCtrlTargetSuppressed and frame.SetAttribute then
            frame:SetAttribute("ctrl-type1", frame.MultibotOriginalCtrlType1)
            frame.MultibotCtrlTargetSuppressed = false
        end
    end
    self.pendingSecureSelectionUpdate = false
end

-- A low-strata mouse catcher sits above the 3D world but below normal UI
-- frames. It is enabled only while Ctrl is held. This lets Ctrl+Left-click on
-- empty world space clear PRIMARY without allowing the normal WorldFrame click
-- to clear the player's current target. Normal world clicks are untouched.
function MBUF:CreateWorldSelectionCatcher()
    if self.worldSelectionCatcher then return self.worldSelectionCatcher end
    if not WorldFrame then return nil end

    local catcher = CreateFrame("Button", nil, WorldFrame)
    catcher:SetAllPoints(WorldFrame)
    if catcher.SetFrameStrata then catcher:SetFrameStrata("BACKGROUND") end
    if catcher.SetFrameLevel and WorldFrame.GetFrameLevel then
        catcher:SetFrameLevel((WorldFrame:GetFrameLevel() or 0) + 1)
    end
    catcher:RegisterForClicks("LeftButtonUp")
    catcher:EnableMouse(true)
    catcher:Hide()
    catcher:SetScript("OnClick", function(_, button)
        if button ~= "LeftButton" then return end
        if not MBUF.enabled then return end
        local db = MBUF:GetDB()
        if not db.selection or db.selection.clickEnabled ~= true then return end
        if not IsControlKeyDown or not IsControlKeyDown() then return end
        API:ClearSelection("PRIMARY")
    end)

    self.worldSelectionCatcher = catcher
    return catcher
end

function MBUF:UpdateWorldSelectionCatcher()
    local catcher = self:CreateWorldSelectionCatcher()
    if not catcher then return end

    local db = self:GetDB()
    local shouldShow = self.enabled == true
        and db.enabled == true
        and db.selection
        and db.selection.clickEnabled == true
        and IsControlKeyDown
        and IsControlKeyDown()

    if shouldShow then
        catcher:Show()
    else
        catcher:Hide()
    end
end

function MBUF:SetSelectionClickEnabled(value)
    local db = self:GetDB()
    db.selection = db.selection or {}
    db.selection.clickEnabled = value == true
    self:UpdateAllSelectionClickBehavior()
    self:UpdateWorldSelectionCatcher()
end

function MBUF:CreateSelectionHighlight(frame)
    if not frame then return nil end
    if frame.MultibotSelectionOverlay then return frame.MultibotSelectionOverlay end

    if InCombatLockdown and InCombatLockdown() then
        self.pendingScan = true
        return nil
    end

    local overlay = CreateFrame("Frame", nil, frame)
    overlay:SetAllPoints(frame)
    if frame.GetFrameStrata and overlay.SetFrameStrata then
        overlay:SetFrameStrata(frame:GetFrameStrata())
    end

    local baseLevel = frame.GetFrameLevel and (frame:GetFrameLevel() or 0) or 0
    if frame.RaisedElementParent and frame.RaisedElementParent.GetFrameLevel then
        local raisedLevel = frame.RaisedElementParent:GetFrameLevel() or baseLevel
        if raisedLevel > baseLevel then baseLevel = raisedLevel end
    end
    if overlay.SetFrameLevel then overlay:SetFrameLevel(baseLevel + 2) end
    if overlay.EnableMouse then overlay:EnableMouse(false) end

    overlay.top = overlay:CreateTexture(nil, "OVERLAY")
    overlay.bottom = overlay:CreateTexture(nil, "OVERLAY")
    overlay.left = overlay:CreateTexture(nil, "OVERLAY")
    overlay.right = overlay:CreateTexture(nil, "OVERLAY")
    overlay:Hide()

    frame.MultibotSelectionOverlay = overlay
    return overlay
end

function MBUF:UpdateSelectionHighlightLayout(frame)
    if not frame then return end
    local overlay = self:CreateSelectionHighlight(frame)
    if not overlay then return end

    local settings = self:GetDB().selection or DEFAULTS.selection
    local size = tonumber(settings.borderSize) or 2
    if size < 1 then size = 1 end
    if size > 6 then size = 6 end

    local color = settings.color or DEFAULTS.selection.color
    local r = tonumber(color.r) or 0.20
    local g = tonumber(color.g) or 0.80
    local b = tonumber(color.b) or 1.00
    local a = tonumber(color.a) or 1.00

    local textures = { overlay.top, overlay.bottom, overlay.left, overlay.right }
    for _, texture in ipairs(textures) do
        if texture then texture:SetTexture(r, g, b, a) end
    end

    overlay.top:ClearAllPoints()
    overlay.top:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    overlay.top:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    overlay.top:SetHeight(size)

    overlay.bottom:ClearAllPoints()
    overlay.bottom:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
    overlay.bottom:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    overlay.bottom:SetHeight(size)

    overlay.left:ClearAllPoints()
    overlay.left:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    overlay.left:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
    overlay.left:SetWidth(size)

    overlay.right:ClearAllPoints()
    overlay.right:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    overlay.right:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    overlay.right:SetWidth(size)
end

function MBUF:UpdateSelectionHighlight(frame, bot, selectedSet)
    if not frame then return false end

    local overlay = self:CreateSelectionHighlight(frame)
    if not overlay then return false end
    self:UpdateSelectionHighlightLayout(frame)

    local db = self:GetDB()
    if not bot or db.enabled ~= true or not db.selection or db.selection.highlightEnabled ~= true then
        overlay:Hide()
        return false
    end

    if not selectedSet then
        local _, current = self:GetPrimarySelection()
        selectedSet = current
    end

    local key = tostring(bot.key or "")
    if key ~= "" and selectedSet[key] == true then
        overlay:Show()
        return overlay:IsShown() and true or false
    end

    overlay:Hide()
    return false
end

function MBUF:RefreshSelectionHighlights()
    local selection, selectedSet = self:GetPrimarySelection()
    local shown = 0

    for frame in pairs(self.trackedFrames) do
        if frame and IsSupportedFrame(frame) then
            local bot = self:GetUnitBot(frame)
            if self:UpdateSelectionHighlight(frame, bot, selectedSet) then
                shown = shown + 1
            end
        end
    end

    self.stats.selectedBotFrames = shown
    self.stats.primarySelectionCount = tonumber(selection.count) or 0
end

function MBUF:OnFrameMouseUp(frame, button)
    if not self.enabled or button ~= "LeftButton" then return end
    local db = self:GetDB()
    if not db.selection or db.selection.clickEnabled ~= true then return end
    if not IsControlKeyDown or not IsControlKeyDown() then return end

    local bot = self:GetUnitBot(frame)
    if not bot then return end

    API:ToggleSelection("PRIMARY", bot.key or bot.name)
end

function MBUF:CreateIndicator(frame)
    if not frame then return nil end
    if frame.MultibotIndicator then
        self:UpdateIndicatorLayout(frame)
        return frame.MultibotIndicator
    end

    if InCombatLockdown and InCombatLockdown() then
        self.pendingScan = true
        return nil
    end

    local host, hostKind = self:GetIndicatorHost(frame)
    local indicator

    if hostKind == "RaisedElementParent" then
        indicator = host:CreateFontString(nil, "OVERLAY")
        frame.MultibotIndicatorHost = host
        frame.MultibotIndicatorHostKind = hostKind
    else
        local overlay = CreateFrame("Frame", nil, frame)
        overlay:SetAllPoints(frame)
        if frame.GetFrameStrata and overlay.SetFrameStrata then
            overlay:SetFrameStrata(frame:GetFrameStrata())
        end
        if frame.GetFrameLevel and overlay.SetFrameLevel then
            overlay:SetFrameLevel((frame:GetFrameLevel() or 0) + 100)
        end
        if overlay.EnableMouse then overlay:EnableMouse(false) end
        overlay:Show()

        indicator = overlay:CreateFontString(nil, "OVERLAY")
        frame.MultibotOverlay = overlay
        frame.MultibotIndicatorHost = overlay
        frame.MultibotIndicatorHostKind = hostKind
    end

    indicator:SetJustifyH("RIGHT")
    indicator:SetJustifyV("TOP")
    indicator:Hide()

    frame.MultibotIndicator = indicator
    self:UpdateIndicatorLayout(frame)
    return indicator
end

function MBUF:TrackFrame(frame)
    if not frame or not IsSupportedFrame(frame) then return end
    self.trackedFrames[frame] = true
    self:UpdateFrameSelectionClickBehavior(frame)

    if not frame.MultibotOnShowHooked and frame.HookScript then
        frame:HookScript("OnShow", function()
            if MBUF.enabled then
                MBUF:QueueDeferredRefresh(0.05)
            end
        end)
        frame.MultibotOnShowHooked = true
    end

    if not frame.MultibotSelectionClickHooked and frame.HookScript then
        frame:HookScript("OnMouseUp", function(_, button)
            MBUF:OnFrameMouseUp(frame, button)
        end)
        frame.MultibotSelectionClickHooked = true
    end
end

function MBUF:RefreshFrame(frame, selectedSet)
    if not IsSupportedFrame(frame) then return false, false, false, false, false end

    self:TrackFrame(frame)

    local bot = self:GetUnitBot(frame)
    if bot then
        frame.MultibotBotKey = bot.key
        frame.MultibotBotName = bot.name
    else
        frame.MultibotBotKey = nil
        frame.MultibotBotName = nil
    end

    local db = self:GetDB()
    local shouldShow = bot ~= nil and db.enabled == true and db.indicator.enabled == true

    local indicator = self:CreateIndicator(frame)
    local indicatorVisible = false
    if indicator then
        self:UpdateIndicatorLayout(frame)
        if shouldShow then
            if frame.MultibotOverlay then frame.MultibotOverlay:Show() end
            indicator:Show()
            indicatorVisible = RegionIsVisible(indicator)
        else
            indicator:Hide()
        end
    end

    local roleVisible, specVisible, movementVisible, xpVisible, inventoryVisible, durabilityVisible, currencyVisible, questVisible = self:UpdateInfoTexts(frame, bot)
    local selectionVisible = self:UpdateSelectionHighlight(frame, bot, selectedSet)
    return true, bot ~= nil, indicatorVisible, roleVisible, specVisible, movementVisible, xpVisible, inventoryVisible, durabilityVisible, currencyVisible, questVisible, selectionVisible
end

function MBUF:RunDeferredRefresh()
    self.deferredRefreshTimer = nil
    if self.enabled then
        self:RefreshAll()
    end
end

function MBUF:QueueDeferredRefresh(delay)
    if not self.enabled then return end
    delay = tonumber(delay) or 0.10

    if self.deferredRefreshTimer and self.CancelTimer then
        self:CancelTimer(self.deferredRefreshTimer, true)
        self.deferredRefreshTimer = nil
    end

    if self.ScheduleTimer then
        self.deferredRefreshTimer = self:ScheduleTimer("RunDeferredRefresh", delay)
    else
        self:RefreshAll()
    end
end

function MBUF:GetRequiredDataDomains()
    local db = self:GetDB()
    local required = {}

    -- GetBotSpec() derives from BOT.DETAIL talent-point fields.
    if db.specText.enabled == true or db.roleText.enabled == true then
        required["BOT.DETAIL"] = true
    end

    -- GetBotRole() prefers BOT.STATE strategies and then falls back to class/spec.
    if db.roleText.enabled == true or db.movementText.enabled == true then
        required["BOT.STATE"] = true
    end

    -- XP, inventory usage, durability and money are fields of one shared BOT.STATS snapshot.
    if db.xpText.enabled == true or db.inventoryText.enabled == true or db.durabilityText.enabled == true or db.currencyText.enabled == true then
        required["BOT.STATS"] = true
    end

    -- Quest-log occupancy comes from Core's authoritative structured quest view.
    if db.questText.enabled == true then
        required["BOT.QUESTS"] = true
    end

    return required
end

function MBUF:ReconcileDataInterests(activeBots)
    activeBots = activeBots or {}
    local required = self:GetRequiredDataDomains()
    local releases = {}

    -- Do not mutate the interest tables while traversing them. Lua 5.1 table
    -- iteration can otherwise skip a sibling domain when multiple releases are
    -- required in the same reconciliation pass.
    for botKey, domains in pairs(self.dataInterests) do
        for domainId in pairs(domains) do
            if not activeBots[botKey] or not required[domainId] then
                releases[#releases + 1] = { botKey = botKey, domainId = domainId }
            end
        end
    end

    for _, item in ipairs(releases) do
        API:Release(MODULE_NAME, item.domainId, item.botKey)
        local domains = self.dataInterests[item.botKey]
        if domains then domains[item.domainId] = nil end
    end

    local emptyBots = {}
    for botKey, domains in pairs(self.dataInterests) do
        if not activeBots[botKey] or next(domains) == nil then
            emptyBots[#emptyBots + 1] = botKey
        end
    end
    for _, botKey in ipairs(emptyBots) do
        self.dataInterests[botKey] = nil
    end

    if next(required) ~= nil then
        for botKey in pairs(activeBots) do
            local domains = self.dataInterests[botKey]
            if not domains then
                domains = {}
                self.dataInterests[botKey] = domains
            end

            for domainId in pairs(required) do
                if not domains[domainId] then
                    local interestKey = API:Acquire(MODULE_NAME, domainId, botKey)
                    if interestKey then domains[domainId] = true end
                end
            end
        end
    end

    local count = 0
    for _ in pairs(self.dataInterests) do count = count + 1 end
    self.stats.interestedBots = count
end

function MBUF:ReleaseAllDataInterests()
    for botKey, domains in pairs(self.dataInterests) do
        for domainId in pairs(domains) do
            API:Release(MODULE_NAME, domainId, botKey)
        end
    end
    self.dataInterests = {}
    self.stats.interestedBots = 0
end

function MBUF:RefreshBotPresentation(targetKey)
    if not targetKey then return end
    for frame in pairs(self.trackedFrames) do
        if frame and frame.MultibotBotKey == targetKey then
            self:RefreshFrame(frame)
        end
    end
end

function MBUF:RunPendingDataRefresh()
    self.dataRefreshTimer = nil
    local targets = self.pendingDataTargets
    self.pendingDataTargets = {}
    for targetKey in pairs(targets) do
        self:RefreshBotPresentation(targetKey)
    end
end

function MBUF:QueueDataPresentationRefresh(targetKey)
    if not self.enabled or not targetKey then return end
    self.pendingDataTargets[targetKey] = true
    if self.dataRefreshTimer then return end

    if self.ScheduleTimer then
        self.dataRefreshTimer = self:ScheduleTimer("RunPendingDataRefresh", 0.02)
    else
        self:RunPendingDataRefresh()
    end
end

function MBUF:OnCoreDataChanged(_, domainId, targetKey)
    if domainId ~= "BOT.DETAIL" and domainId ~= "BOT.STATE" and domainId ~= "BOT.STATS" and domainId ~= "BOT.QUESTS" then return end
    if not self.dataInterests[targetKey] then return end

    -- BOT.DETAIL's public data event is emitted immediately before Core merges
    -- the detail into the bot-registry fields consumed by GetBotSpec(). Defer
    -- presentation only, allowing the Core protocol handler to finish first.
    self:QueueDataPresentationRefresh(targetKey)
end

function MBUF:ScanFrames()
    self.stats.scans = self.stats.scans + 1
    self.stats.eligibleFrames = 0
    self.stats.resolvedBotFrames = 0
    self.stats.shownIndicators = 0
    self.stats.shownRoleTexts = 0
    self.stats.shownSpecTexts = 0
    self.stats.shownMovementTexts = 0
    self.stats.shownXPTexts = 0
    self.stats.shownInventoryTexts = 0
    self.stats.shownDurabilityTexts = 0
    self.stats.shownCurrencyTexts = 0
    self.stats.shownQuestTexts = 0
    self.stats.selectedBotFrames = 0

    local selection, selectedSet = self:GetPrimarySelection()
    self.stats.primarySelectionCount = tonumber(selection.count) or 0

    if not ElvUF or type(ElvUF.objects) ~= "table" then
        self:ReconcileDataInterests({})
        return false
    end

    local activeBots = {}

    for _, frame in pairs(ElvUF.objects) do
        if IsSupportedFrame(frame) then
            local eligible, isBot, indicatorShown, roleShown, specShown, movementShown, xpShown, inventoryShown, durabilityShown, currencyShown, questShown, selectionShown = self:RefreshFrame(frame, selectedSet)
            if eligible then self.stats.eligibleFrames = self.stats.eligibleFrames + 1 end
            if isBot then
                self.stats.resolvedBotFrames = self.stats.resolvedBotFrames + 1
                if frame.MultibotBotKey then activeBots[frame.MultibotBotKey] = true end
            end
            if indicatorShown then self.stats.shownIndicators = self.stats.shownIndicators + 1 end
            if roleShown then self.stats.shownRoleTexts = self.stats.shownRoleTexts + 1 end
            if specShown then self.stats.shownSpecTexts = self.stats.shownSpecTexts + 1 end
            if movementShown then self.stats.shownMovementTexts = self.stats.shownMovementTexts + 1 end
            if xpShown then self.stats.shownXPTexts = self.stats.shownXPTexts + 1 end
            if inventoryShown then self.stats.shownInventoryTexts = self.stats.shownInventoryTexts + 1 end
            if durabilityShown then self.stats.shownDurabilityTexts = self.stats.shownDurabilityTexts + 1 end
            if currencyShown then self.stats.shownCurrencyTexts = self.stats.shownCurrencyTexts + 1 end
            if questShown then self.stats.shownQuestTexts = self.stats.shownQuestTexts + 1 end
            if selectionShown then self.stats.selectedBotFrames = self.stats.selectedBotFrames + 1 end
        end
    end

    self:ReconcileDataInterests(activeBots)
    return true
end

function MBUF:RefreshAll()
    self:ScanFrames()
end

function MBUF:OnCoreRegistryReady()
    self:RefreshAll()
    self:QueueDeferredRefresh(0.10)
end

function MBUF:OnBotRegistryChanged()
    self:RefreshAll()
    self:QueueDeferredRefresh(0.10)
end

function MBUF:OnRosterChanged()
    self:RefreshAll()
    self:QueueDeferredRefresh(0.10)
end

function MBUF:OnElvUIUnitFramesUpdated()
    -- Called after ElvUI completes its own full UnitFrame update. This is the
    -- deterministic point to reapply profile-dependent presentation after reload
    -- or an ElvUI profile/settings refresh.
    self:RefreshAll()
    self:QueueDeferredRefresh(0.05)
end

function MBUF:HookElvUIUnitFrames()
    if self.elvUIHooked then return end
    if not UF or type(UF.Update_AllFrames) ~= "function" then return end

    self:SecureHook(UF, "Update_AllFrames", "OnElvUIUnitFramesUpdated")
    self.elvUIHooked = true
end

function MBUF:PLAYER_REGEN_ENABLED()
    if self.pendingSecureSelectionUpdate then
        self:UpdateAllSelectionClickBehavior()
    end
    if self.pendingScan then
        self.pendingScan = false
        self:RefreshAll()
    end
end

function MBUF:MODIFIER_STATE_CHANGED()
    self:UpdateWorldSelectionCatcher()
end

function MBUF:PLAYER_ENTERING_WORLD()
    self:UpdateAllSelectionClickBehavior()
    self:UpdateWorldSelectionCatcher()
    self:RefreshAll()
    self:QueueDeferredRefresh(0.25)
end

function MBUF:PARTY_MEMBERS_CHANGED()
    self:OnRosterChanged()
end

function MBUF:RAID_ROSTER_UPDATE()
    self:OnRosterChanged()
end

function MBUF:UNIT_NAME_UPDATE()
    self:RefreshAll()
    self:QueueDeferredRefresh(0.05)
end

function MBUF:RegisterCoreSubscriptions()
    self.subscriptions[#self.subscriptions + 1] = API:Subscribe(
        MODULE_NAME,
        "MB_BOT_REGISTRY_READY",
        function() MBUF:OnCoreRegistryReady() end
    )

    self.subscriptions[#self.subscriptions + 1] = API:Subscribe(
        MODULE_NAME,
        "MB_BOT_DISCOVERED",
        function() MBUF:OnBotRegistryChanged() end
    )

    self.subscriptions[#self.subscriptions + 1] = API:Subscribe(
        MODULE_NAME,
        "MB_BOT_PRESENCE_CHANGED",
        function() MBUF:OnBotRegistryChanged() end
    )

    self.subscriptions[#self.subscriptions + 1] = API:Subscribe(
        MODULE_NAME,
        "MB_SESSION_CHANGED",
        function() MBUF:RefreshAll() end
    )

    self.subscriptions[#self.subscriptions + 1] = API:Subscribe(
        MODULE_NAME,
        "MB_DATA_CHANGED",
        function(...) MBUF:OnCoreDataChanged(...) end
    )

    self.subscriptions[#self.subscriptions + 1] = API:Subscribe(
        MODULE_NAME,
        "MB_SELECTION_CHANGED",
        function(_, selectionId)
            if tostring(selectionId or "") == "PRIMARY" then
                MBUF:RefreshSelectionHighlights()
            end
        end
    )
end

function MBUF:HideAllIndicators()
    for frame in pairs(self.trackedFrames) do
        if frame then
            if frame.MultibotIndicator then frame.MultibotIndicator:Hide() end
            if frame.MultibotRoleText then frame.MultibotRoleText:Hide() end
            if frame.MultibotSpecText then frame.MultibotSpecText:Hide() end
            if frame.MultibotMovementText then frame.MultibotMovementText:Hide() end
            if frame.MultibotXPText then frame.MultibotXPText:Hide() end
            if frame.MultibotInventoryText then frame.MultibotInventoryText:Hide() end
            if frame.MultibotDurabilityText then frame.MultibotDurabilityText:Hide() end
            if frame.MultibotCurrencyText then frame.MultibotCurrencyText:Hide() end
            if frame.MultibotSelectionOverlay then frame.MultibotSelectionOverlay:Hide() end
            frame.MultibotBotKey = nil
            frame.MultibotBotName = nil
        end
    end
end

function MBUF:EnableModule()
    if self.enabled then return true end
    if not self:IsProfileDBReady() then return false end

    local db = self:GetDB()
    if db.enabled ~= true then
        self:HideAllIndicators()
        return
    end

    self.enabled = true

    API:RegisterModule(MODULE_NAME, {
        version = VERSION,
        description = "ElvUI party/raid UnitFrame presentation for Multibot Core 1.0",
    })
    self.coreRegistered = true

    self:RegisterCoreSubscriptions()
    self:HookElvUIUnitFrames()

    self:RegisterEvent("PLAYER_ENTERING_WORLD")
    self:RegisterEvent("PLAYER_REGEN_ENABLED")
    self:RegisterEvent("PARTY_MEMBERS_CHANGED")
    self:RegisterEvent("RAID_ROSTER_UPDATE")
    self:RegisterEvent("UNIT_NAME_UPDATE")
    self:RegisterEvent("MODIFIER_STATE_CHANGED")

    self:CreateWorldSelectionCatcher()
    self:UpdateAllSelectionClickBehavior()
    self:UpdateWorldSelectionCatcher()
    self:RefreshAll()
    if API:IsBotRegistryReady() then
        self:RefreshAll()
    end
    self:QueueDeferredRefresh(0.25)
    return true
end

function MBUF:DisableModule()
    if not self.enabled and not self.coreRegistered then
        self:HideAllIndicators()
        if self.worldSelectionCatcher then self.worldSelectionCatcher:Hide() end
        return
    end

    self:RestoreSelectionClickBehavior()
    if self.worldSelectionCatcher then self.worldSelectionCatcher:Hide() end
    self.enabled = false
    self:UnregisterAllEvents()
    self:HideAllIndicators()
    self:ReleaseAllDataInterests()

    if self.dataRefreshTimer and self.CancelTimer then
        self:CancelTimer(self.dataRefreshTimer, true)
    end
    self.dataRefreshTimer = nil
    self.pendingDataTargets = {}

    if self.coreRegistered then
        API:UnregisterModule(MODULE_NAME)
        self.coreRegistered = false
    end

    self.subscriptions = {}
    self.pendingScan = false

    if self.deferredRefreshTimer and self.CancelTimer then
        self:CancelTimer(self.deferredRefreshTimer, true)
    end
    self.deferredRefreshTimer = nil
end

function MBUF:OnElvUIProfileChanged()
    -- E.db now points at a different/copy/reset profile. Re-read that profile
    -- and make runtime state follow the newly active saved configuration.
    if not self:IsProfileDBReady() then return end
    self:GetDB()
    self:EnsureRuntimeState("ELVUI_PROFILE_CHANGED")
end

function MBUF:RegisterProfileCallbacks()
    if self.profileCallbacksRegistered then return end
    if not (E.data and E.data.RegisterCallback) then return end

    E.data.RegisterCallback(self, "OnProfileChanged", "OnElvUIProfileChanged")
    E.data.RegisterCallback(self, "OnProfileCopied", "OnElvUIProfileChanged")
    E.data.RegisterCallback(self, "OnProfileReset", "OnElvUIProfileChanged")
    self.profileCallbacksRegistered = true
end

function MBUF:EnsureRuntimeState(reason)
    if not self:IsProfileDBReady() then return false end

    local db = self:GetDB()
    self.lastBootstrapReason = tostring(reason or self.lastBootstrapReason or "unknown")

    if db.enabled == true then
        if not self.enabled then
            if not self:EnableModule() then return false end
        else
            self:RefreshAll()
            self:QueueDeferredRefresh(0.10)
        end
    elseif self.enabled or self.coreRegistered then
        self:DisableModule()
    else
        self:HideAllIndicators()
    end

    return true
end

function MBUF:Bootstrap(reason)
    -- Compatibility entry used by option changes after the ElvUI-managed
    -- initialization has completed. It is no longer a file-load/login fallback.
    if not self.lifecycleReady or not self.initialized or not self:IsProfileDBReady() then
        return false
    end

    self.bootstrapAttempts = (self.bootstrapAttempts or 0) + 1
    self.lastBootstrapReason = tostring(reason or "unknown")
    return self:EnsureRuntimeState(reason or "BOOTSTRAP")
end

function MBUF:SetModuleEnabled(value)
    if not self:IsProfileDBReady() then return end
    local db = self:GetDB()
    db.enabled = value == true

    if db.enabled then
        self:EnableModule()
        self:RefreshAll()
    else
        self:DisableModule()
    end
end

function MBUF:ApplyPresentationSettings()
    if not self:Bootstrap("OPTIONS_APPLY") then return end
    if self.enabled then
        self:UpdateAllSelectionClickBehavior()
        self:UpdateWorldSelectionCatcher()
        self:RefreshAll()
    end
end

function MBUF:PrintStatus()
    local objects = ElvUF and ElvUF.objects
    local objectCount = 0
    if type(objects) == "table" then
        for _ in pairs(objects) do objectCount = objectCount + 1 end
    end

    local db = self:GetDB()
    Print(format(
        "%s | Core API %s | Core %s | registry=%s | configured=%s | runtime=%s | PB=%s | Role=%s | Spec=%s | Movement=%s | XP=%s | Inventory=%s | Durability=%s | Currency=%s | Quest=%s | Selection=%s/%s | worldClear=%s | db=%s | init=%s | boot=%s/%d | ElvUF objects=%d | eligible=%d | resolved bots=%d | visible PB=%d | role=%d | spec=%d | movement=%d | xp=%d | inventory=%d | durability=%d | currency=%d | quest=%d | selectedFrames=%d | primary=%d | interests=%d | scans=%d",
        VERSION,
        tostring(API:GetVersion()),
        tostring(API:GetCoreVersion()),
        API:IsBotRegistryReady() and "ready" or "pending",
        db.enabled and "enabled" or "disabled",
        self.enabled and "enabled" or "disabled",
        db.indicator.enabled and "enabled" or "disabled",
        db.roleText.enabled and "enabled" or "disabled",
        db.specText.enabled and "enabled" or "disabled",
        db.movementText.enabled and "enabled" or "disabled",
        db.xpText.enabled and "enabled" or "disabled",
        db.inventoryText.enabled and "enabled" or "disabled",
        db.durabilityText.enabled and "enabled" or "disabled",
        db.currencyText.enabled and "enabled" or "disabled",
        db.questText.enabled and "enabled" or "disabled",
        db.selection and db.selection.clickEnabled and "ctrl-click" or "click-off",
        db.selection and db.selection.highlightEnabled and "highlight" or "highlight-off",
        self.worldSelectionCatcher and (self.worldSelectionCatcher:IsShown() and "armed" or "ready") or "missing",
        self:IsProfileDBReady() and "ElvUI-profile-ready" or "profile-not-ready",
        self.initialized and "yes" or "no",
        tostring(self.lastBootstrapReason or "-"),
        tonumber(self.bootstrapAttempts) or 0,
        objectCount,
        self.stats.eligibleFrames or 0,
        self.stats.resolvedBotFrames or 0,
        self.stats.shownIndicators or 0,
        self.stats.shownRoleTexts or 0,
        self.stats.shownSpecTexts or 0,
        self.stats.shownMovementTexts or 0,
        self.stats.shownXPTexts or 0,
        self.stats.shownInventoryTexts or 0,
        self.stats.shownDurabilityTexts or 0,
        self.stats.shownCurrencyTexts or 0,
        self.stats.shownQuestTexts or 0,
        self.stats.selectedBotFrames or 0,
        self.stats.primarySelectionCount or 0,
        self.stats.interestedBots or 0,
        self.stats.scans or 0
    ))
end

function MBUF:PrintFrames()
    local found = 0
    if ElvUF and type(ElvUF.objects) == "table" then
        for _, frame in pairs(ElvUF.objects) do
            if IsSupportedFrame(frame) and frame.unit and UnitExists(frame.unit) then
                found = found + 1
                local unitName = UnitName(frame.unit)
                local record = unitName and API:GetBot(unitName) or nil
                local bot = record and record.online == true and record or nil
                local indicator = frame.MultibotIndicator
                local suffix

                if bot then
                    suffix = " | BOT=" .. tostring(bot.name) .. " | online"
                elseif record then
                    suffix = " | Core record exists but not bridge-online"
                else
                    suffix = " | human/unresolved"
                end

                local frameLevel = frame.GetFrameLevel and frame:GetFrameLevel() or "?"
                local hostLevel = frame.MultibotIndicatorHost and frame.MultibotIndicatorHost.GetFrameLevel and frame.MultibotIndicatorHost:GetFrameLevel() or "?"
                local indicatorShown = indicator and indicator:IsShown() and true or false
                local indicatorVisible = RegionIsVisible(indicator)
                local roleRegion = frame.MultibotRoleText
                local specRegion = frame.MultibotSpecText
                local movementRegion = frame.MultibotMovementText
                local xpRegion = frame.MultibotXPText
                local inventoryRegion = frame.MultibotInventoryText
                local durabilityRegion = frame.MultibotDurabilityText
                local currencyRegion = frame.MultibotCurrencyText
                local questRegion = frame.MultibotQuestText
                local roleValue = bot and self:GetRoleDisplay(bot.key or bot.name) or "-"
                local specValue = bot and self:GetSpecDisplay(bot.key or bot.name) or "-"
                local movementValue = bot and self:GetMovementDisplay(bot.key or bot.name) or "-"
                local xpValue = bot and self:GetXPDisplay(bot.key or bot.name) or "-"
                local inventoryValue = bot and self:GetInventoryDisplay(bot.key or bot.name) or "-"
                local durabilityValue = bot and self:GetDurabilityDisplay(bot.key or bot.name) or "-"
                local currencyValue = bot and self:GetCurrencyDisplay(bot.key or bot.name) or "-"
                local questValue = bot and self:GetQuestDisplay(bot.key or bot.name) or "-"
                local selection, selectedSet = self:GetPrimarySelection()
                local selected = bot and selectedSet[tostring(bot.key or "")] == true or false

                suffix = suffix
                    .. " | frameShown=" .. tostring(frame:IsShown() and true or false)
                    .. " | PBshown=" .. tostring(indicatorShown)
                    .. " | PBvisible=" .. tostring(indicatorVisible)
                    .. " | role=" .. tostring(roleValue)
                    .. "/" .. tostring(RegionIsVisible(roleRegion))
                    .. " | spec=" .. tostring(specValue)
                    .. "/" .. tostring(RegionIsVisible(specRegion))
                    .. " | movement=" .. tostring(movementValue)
                    .. "/" .. tostring(RegionIsVisible(movementRegion))
                    .. " | xp=" .. tostring(xpValue)
                    .. "/" .. tostring(RegionIsVisible(xpRegion))
                    .. " | inventory=" .. tostring(inventoryValue)
                    .. "/" .. tostring(RegionIsVisible(inventoryRegion))
                    .. " | durability=" .. tostring(durabilityValue)
                    .. "/" .. tostring(RegionIsVisible(durabilityRegion))
                    .. " | currency=" .. tostring(currencyValue)
                    .. "/" .. tostring(RegionIsVisible(currencyRegion))
                    .. " | quest=" .. tostring(questValue)
                    .. "/" .. tostring(RegionIsVisible(questRegion))
                    .. " | selected=" .. tostring(selected)
                    .. " | highlight=" .. tostring(frame.MultibotSelectionOverlay and frame.MultibotSelectionOverlay:IsShown() or false)
                    .. " | ctrlTargetSuppressed=" .. tostring(frame.MultibotCtrlTargetSuppressed == true)
                    .. " | host=" .. tostring(frame.MultibotIndicatorHostKind or "-")
                    .. " | levels=" .. tostring(frameLevel) .. "/" .. tostring(hostLevel)
                    .. " | boundBot=" .. tostring(frame.MultibotBotName or "-")

                Print(format(
                    "%s -> %s%s",
                    tostring(frame.unit),
                    tostring(unitName or "?"),
                    suffix
                ))
            end
        end
    end
    if found == 0 then Print("No active supported party/raid frames found.") end
end

function MBUF:PrintSelection()
    local selection = API:GetSelection("PRIMARY")
    if type(selection) ~= "table" or tonumber(selection.count) == 0 then
        Print("PRIMARY selection: empty")
        return
    end

    local names = {}
    for _, bot in ipairs(selection.bots or {}) do
        names[#names + 1] = tostring(bot.name or bot.key or "?")
    end
    Print(format("PRIMARY selection (%d): %s", tonumber(selection.count) or #names, table.concat(names, ", ")))
end

local function PrintSlashHelp()
    Print("Commands: /mbuf status, /mbuf scan, /mbuf frames, /mbuf selection, /mbuf help")
end

SLASH_ELVUIMULTIBOTUNITFRAMES1 = "/mbuf"
SlashCmdList.ELVUIMULTIBOTUNITFRAMES = function(msg)
    msg = string.lower(tostring(msg or ""))
    msg = msg:gsub("^%s+", ""):gsub("%s+$", "")

    -- Ignore an accidental duplicate dispatch of the exact same slash command
    -- in the same input gesture. This does not affect deliberate later calls.
    local now = GetTime and GetTime() or 0
    if MBUF.lastSlashCommand == msg and now > 0 and MBUF.lastSlashCommandTime and (now - MBUF.lastSlashCommandTime) < 0.25 then
        return
    end
    MBUF.lastSlashCommand = msg
    MBUF.lastSlashCommandTime = now

    -- Keep diagnostics deterministic: one requested diagnostic produces one
    -- diagnostic result. In particular, explicit /mbuf status no longer falls
    -- through the generic help path.
    if msg == "status" then
        MBUF:PrintStatus()
    elseif msg == "scan" then
        MBUF:RefreshAll()
        MBUF:PrintStatus()
    elseif msg == "frames" then
        MBUF:PrintFrames()
    elseif msg == "selection" then
        MBUF:PrintSelection()
    elseif msg == "" or msg == "help" then
        PrintSlashHelp()
    else
        Print("Unknown command: " .. tostring(msg))
        PrintSlashHelp()
    end
end

function MBUF:Initialize()
    if self.initialized then return end

    -- This method is entered through LibElvUIPlugin's ElvUI 6.09 post-initialize
    -- lifecycle. Do not bind runtime services until the active profile exists.
    if type(E.data) ~= "table" or type(E.db) ~= "table" then
        Print("Initialization aborted: ElvUI database is not ready.")
        return
    end

    ElvUF = E.oUF or ElvUI.oUF
    UF = E:GetModule("UnitFrames", true)

    Core = _G.ElvUI_Multibot_Core
    if not Core or type(Core.GetAPI) ~= "function" then
        Print("Initialization aborted: ElvUI_Multibot_Core API is unavailable.")
        return
    end

    API = Core:GetAPI(1)
    if not API then
        Print("Initialization aborted: ElvUI_Multibot_Core API v1 is unavailable.")
        return
    end

    self.api = API
    self.lifecycleReady = true

    local migrated = self:MigrateLegacyDB()
    self:GetDB()
    self:RegisterProfileCallbacks()

    -- Options.lua supplies this method. Registration remains lazy through
    -- Options.lua registers through LibElvUIPlugin only.
    if type(self.RegisterOptions) == "function" then
        self:RegisterOptions()
    end

    self.initialized = true
    self.bootstrapAttempts = (self.bootstrapAttempts or 0) + 1
    self.lastBootstrapReason = "ELVUI_PLUGIN_INITIALIZE"

    if migrated then
        Print("Migrated Alpha 1 settings into the current ElvUI profile.")
    end

    self:EnsureRuntimeState("ELVUI_PLUGIN_INITIALIZE")
end

