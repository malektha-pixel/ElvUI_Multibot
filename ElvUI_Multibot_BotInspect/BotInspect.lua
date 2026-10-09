local addonName = ...

local MODULE = "ElvUI_Multibot_BotInspect"
local VERSION = GetAddOnMetadata(addonName, "Version") or "0.3.0-alpha2.2.8"
local MIN_CORE = "1.6.4.2"
local PREFIX = "|cff1784d1BotInspect|r"

local Core = _G.ElvUI_Multibot_Core
if not Core or type(Core.GetAPI) ~= "function" then return end
local API = Core:GetAPI(1)
if not API then return end

local E, L, V, P, G
if type(ElvUI) == "table" and type(unpack) == "function" then
    E, L, V, P, G = unpack(ElvUI)
end

local DEFAULTS = {
    scale = 1.00,
    itemSize = 32,
    inventoryColumns = 10,
    rosterExpanded = true,
    masterLootEnhancements = true,
    showMicroBarButton = true,
    hotkeyEnabled = true,
    hotkey = "SHIFT-C",
    microbarCapacityMigrated = false,
    microbarCapacityMigrationVersion = 0,
    point = "CENTER",
    relativePoint = "CENTER",
    x = 0,
    y = 0,
}

-- ElvUI 6.09 builds its AceDB profile from P during E:Initialize().
-- Register our profile defaults while files are loading, then bind E.db only
-- after ElvUI's post-initialize lifecycle fires.
if type(P) == "table" then
    P.multibotBotInspect = type(P.multibotBotInspect) == "table" and P.multibotBotInspect or {}
    for key, value in pairs(DEFAULTS) do
        if P.multibotBotInspect[key] == nil then P.multibotBotInspect[key] = value end
    end
end

local MAIN_WIDTH = 790
local ROSTER_WIDTH = 286
local HANDLE_WIDTH = 18
local FRAME_HEIGHT = 636
local MAIN_LEFT_WIDTH = 352
local INVENTORY_WIDTH = 408

-- Efficiency policy for large managed rosters. WoW 3.3.5a executes addon Lua on
-- the UI thread, so bulk lifecycle events, UI rebuilds and large historical
-- inventory copies must not be allowed to burst at the same time.
local UI_EVENT_COALESCE_DELAY = 0.12
local BULK_LIFECYCLE_CONCURRENCY = 2
local BULK_LIFECYCLE_BATCH_GAP = 0.40
local BACKGROUND_SETTLE_DELAY = 2.00
local AUTO_RESOLVE_START_DELAY = 0.30
local HISTORY_PRIME_START_DELAY = 0.75
local HISTORY_DOMAIN_GAP = 0.20
local HISTORY_BOT_GAP = 0.65
local HISTORY_PRIME_MAX_PASSES = 5
local HISTORY_RETRY_DELAYS = { 2.0, 5.0, 10.0, 20.0, 30.0 }

-- Reliability controller for the actively inspected bot. Core BOT.EQUIPMENT is
-- intentionally on-demand and can fail transiently while a unit is becoming
-- visible/inspectable. Retry only the missing domain, with bounded backoff,
-- instead of requiring the user to press Refresh.
local SELECTED_ENSURE_START_DELAY = 0.35
local SELECTED_DOMAIN_GAP = 0.12
local SELECTED_RETRY_DELAYS = { 0.75, 1.5, 3.0, 6.0, 12.0, 20.0 }

local FILTER_ALL = "ALL"
local FILTER_GEAR = "GEAR"
local FILTER_CONSUMABLES = "CONSUMABLES"
local FILTER_QUEST = "QUEST"

local BotInspect = {
    api = API,
    core = Core,
    E = E,
    P = P,
    enabled = false,
    initialized = false,
    uiReady = false,
    selectedBot = nil,
    interests = {},
    subscriptions = {},
    db = nil,
    frame = nil,
    equipmentButtons = {},
    inventoryButtons = {},
    inventoryHeaders = {},
    rosterRows = {},
    rosterOffset = 0,
    rosterEntries = {},
    contextRosterBot = nil,
    lifecyclePending = {},
    presetSummonRunning = false,
    presetSummonState = nil,
    inventoryFilter = FILTER_ALL,
    defaultInventoryAction = nil,
    activeView = "GEAR",
    contextItem = nil,
    contextEquipment = nil,
    autoResolveQueue = {},
    autoResolveQueued = {},
    autoResolveAttempted = {},
    autoResolveActive = 0,
    autoResolveConcurrency = 1,
    historyPrimeQueue = {},
    historyPrimeQueued = {},
    historyPrimeAttempted = {},
    historyPrimeCompleted = {},
    historyPrimeRetryAt = {},
    historyPrimeActiveBots = {},
    historyPrimeActive = 0,
    historyPrimeConcurrency = 1,
    selectedRetryAttempts = {},
    selectedEnsureGeneration = 0,
    scheduledJobs = {},
    schedulerFrame = nil,
    backgroundResumeAt = 0,
    lastKnownSummaryCache = {},
}
_G.ElvUI_Multibot_BotInspect = BotInspect

local SLOT_SHORT = {
    HeadSlot = "Head", NeckSlot = "Neck", ShoulderSlot = "Shoulder", ShirtSlot = "Shirt", ChestSlot = "Chest",
    WaistSlot = "Waist", LegsSlot = "Legs", FeetSlot = "Feet", WristSlot = "Wrist", HandsSlot = "Hands",
    Finger0Slot = "Ring 1", Finger1Slot = "Ring 2", Trinket0Slot = "Trinket 1", Trinket1Slot = "Trinket 2",
    BackSlot = "Back", MainHandSlot = "Main Hand", SecondaryHandSlot = "Off Hand", RangedSlot = "Ranged", TabardSlot = "Tabard",
}

local PAPERDOLL_POSITIONS = {
    [1] = { 10, -50 }, [2] = { 10, -92 }, [3] = { 10, -134 }, [15] = { 10, -176 },
    [5] = { 10, -218 }, [4] = { 10, -260 }, [19] = { 10, -302 }, [9] = { 10, -344 },
    [10] = { 302, -50 }, [6] = { 302, -92 }, [7] = { 302, -134 }, [8] = { 302, -176 },
    [11] = { 302, -218 }, [12] = { 302, -260 }, [13] = { 302, -302 }, [14] = { 302, -344 },
    [16] = { 102, -392 }, [17] = { 154, -392 }, [18] = { 206, -392 },
}

local SPEC_CATALOG = {
    WARRIOR = { "Arms", "Fury", "Protection" },
    PALADIN = { "Holy", "Protection", "Retribution" },
    HUNTER = { "Beast Mastery", "Marksmanship", "Survival" },
    ROGUE = { "Assassination", "Combat", "Subtlety" },
    PRIEST = { "Discipline", "Holy", "Shadow" },
    DEATHKNIGHT = { "Blood", "Frost", "Unholy" },
    SHAMAN = { "Elemental", "Enhancement", "Restoration" },
    MAGE = { "Arcane", "Fire", "Frost" },
    WARLOCK = { "Affliction", "Demonology", "Destruction" },
    DRUID = { "Balance", "Feral", "Restoration" },
}

local HISTORY_PRIME_DOMAINS = {
    "BOT.DETAIL", "BOT.STATS",
    "BOT.INVENTORY_EXACT", "BOT.INVENTORY", "BOT.EQUIPMENT",
}

local SELECTED_GEAR_DOMAINS = {
    "BOT.EQUIPMENT", "BOT.INVENTORY_EXACT", "BOT.INVENTORY",
    "BOT.DETAIL", "BOT.STATS",
}

local SELECTED_SPELLBOOK_DOMAINS = {
    "BOT.SPELLBOOK", "BOT.DETAIL", "BOT.STATS",
}

local RELIABLE_DOMAIN = {}
for _, domainId in ipairs(SELECTED_GEAR_DOMAINS) do RELIABLE_DOMAIN[domainId] = true end
for _, domainId in ipairs(SELECTED_SPELLBOOK_DOMAINS) do RELIABLE_DOMAIN[domainId] = true end

local function trim(value)
    value = tostring(value or "")
    return (string.gsub(value, "^%s*(.-)%s*$", "%1"))
end

local function lower(value) return string.lower(tostring(value or "")) end
local function upper(value) return string.upper(tostring(value or "")) end

local function classKey(value)
    return string.upper(string.gsub(tostring(value or ""), "[^A-Za-z]", ""))
end

local function dominantTreeFromDetail(detail)
    if type(detail) ~= "table" then return nil end
    local points = { tonumber(detail.talent1) or 0, tonumber(detail.talent2) or 0, tonumber(detail.talent3) or 0 }
    local total = points[1] + points[2] + points[3]
    if total <= 0 then return nil end
    local maximum = math.max(points[1], points[2], points[3])
    local winner, ties = nil, 0
    for i = 1, 3 do
        if points[i] == maximum then winner, ties = i, ties + 1 end
    end
    if ties ~= 1 then return nil end
    return winner
end

local function roleForTree(class, tree)
    if class == "MAGE" or class == "WARLOCK" or class == "HUNTER" or class == "ROGUE" then return "DPS" end
    if class == "PRIEST" then return tree == 3 and "DPS" or "HEALER" end
    if class == "SHAMAN" then return tree == 3 and "HEALER" or "DPS" end
    if class == "PALADIN" then return tree == 1 and "HEALER" or (tree == 2 and "TANK" or "DPS") end
    if class == "WARRIOR" then return tree == 3 and "TANK" or "DPS" end
    if class == "DEATHKNIGHT" then return tree == 1 and "TANK" or "DPS" end
    if class == "DRUID" then
        if tree == 1 then return "DPS" end
        if tree == 3 then return "HEALER" end
        if tree == 2 then return "TANK/DPS" end
    end
    return nil
end

local function clamp(value, minimum, maximum)
    value = tonumber(value) or minimum
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function safeCall(object, method, ...)
    if not object then return nil end
    local fn = object[method]
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c, d = pcall(fn, object, ...)
    if not ok then return nil end
    return a, b, c, d
end

local function versionTuple(version)
    local a, b, c, d = string.match(tostring(version or ""), "^(%d+)%.(%d+)%.(%d+)%.?(%d*)")
    return { tonumber(a) or 0, tonumber(b) or 0, tonumber(c) or 0, tonumber(d) or 0 }
end

local function versionAtLeast(version, minimum)
    local a, b = versionTuple(version), versionTuple(minimum)
    for i = 1, 4 do
        if a[i] ~= b[i] then return a[i] > b[i] end
    end
    return true
end

local function moneyText(copper)
    copper = math.max(0, tonumber(copper) or 0)
    local gold = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    local coin = copper % 100
    return string.format("%dg %02ds %02dc", gold, silver, coin)
end

local function percentText(value)
    value = tonumber(value)
    if not value then return "--" end
    return string.format("%.0f%%", value)
end

local function observedAtText(meta)
    local stamp = meta and tonumber(meta.observedAt) or nil
    if not stamp or stamp <= 0 then return "unknown" end
    if type(date) == "function" then
        local ok, value = pcall(date, "%Y-%m-%d %H:%M", stamp)
        if ok and value then return tostring(value) end
    end
    return tostring(stamp)
end

local function ageText(stamp)
    stamp = tonumber(stamp)
    if not stamp or stamp <= 0 then return "never" end
    local now = type(time) == "function" and tonumber(time()) or nil
    if not now then return observedAtText({ observedAt = stamp }) end
    local seconds = math.max(0, now - stamp)
    if seconds < 60 then return "<1m" end
    if seconds < 3600 then return tostring(math.floor(seconds / 60)) .. "m" end
    if seconds < 86400 then return tostring(math.floor(seconds / 3600)) .. "h" end
    return tostring(math.floor(seconds / 86400)) .. "d"
end

local function createBackdrop(frame, alpha)
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        tile = true, tileSize = 8, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    frame:SetBackdropColor(0.045, 0.045, 0.055, alpha or 0.96)
    frame:SetBackdropBorderColor(0.18, 0.18, 0.22, 1)
end

local function setQualityBorder(frame, quality)
    if not frame or not frame.SetBackdropBorderColor then return end
    if quality ~= nil and type(GetItemQualityColor) == "function" then
        local r, g, b = GetItemQualityColor(tonumber(quality) or 1)
        if r then frame:SetBackdropBorderColor(r, g, b, 1); return end
    end
    frame:SetBackdropBorderColor(0.20, 0.20, 0.24, 1)
end

local function createText(parent, size, justifyH)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetFontObject(GameFontNormal)
    if E and E.media and E.media.normFont and fs.SetFont then
        pcall(fs.SetFont, fs, E.media.normFont, size or 12, "OUTLINE")
    elseif fs.SetTextHeight and size then
        fs:SetTextHeight(size)
    end
    if justifyH then fs:SetJustifyH(justifyH) end
    return fs
end

local function createButton(parent, text, width, height)
    local button = CreateFrame("Button", nil, parent)
    button:SetWidth(width or 90)
    button:SetHeight(height or 22)
    createBackdrop(button, 0.95)
    local label = createText(button, 10, "CENTER")
    label:SetPoint("CENTER", button, "CENTER", 0, 0)
    label:SetText(text or "")
    button.label = label
    button:SetScript("OnEnter", function(self) self:SetBackdropColor(0.10, 0.10, 0.12, 1) end)
    button:SetScript("OnLeave", function(self) self:SetBackdropColor(0.045, 0.045, 0.055, 0.95) end)
    return button
end

local function createIconButton(parent, texture, size)
    local button = CreateFrame("Button", nil, parent)
    button:SetWidth(size or 22)
    button:SetHeight(size or 22)
    createBackdrop(button, 0.90)
    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", button, "TOPLEFT", 2, -2)
    icon:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -2, 2)
    icon:SetTexture(texture or "Interface\\Icons\\INV_Misc_QuestionMark")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    button.icon = icon
    return button
end

local function setButtonEnabled(button, enabled)
    if not button then return end
    if enabled then button:Enable() else button:Disable() end
    if button.label then
        if enabled then button.label:SetTextColor(0.95, 0.95, 0.95) else button.label:SetTextColor(0.42, 0.42, 0.45) end
    end
    if button.icon and button.icon.SetDesaturated then button.icon:SetDesaturated(not enabled) end
    if button.icon then button.icon:SetAlpha(enabled and 1 or 0.40) end
end

local function scrollFrameByWheel(scroll, delta, step)
    if not scroll or type(scroll.SetVerticalScroll) ~= "function" then return end
    -- Explicitly refresh the legacy child rectangle before reading the range.
    -- This matters for roster lists whose child grows after SetScrollChild().
    if type(scroll.UpdateScrollChildRect) == "function" then pcall(scroll.UpdateScrollChildRect, scroll) end
    local current = type(scroll.GetVerticalScroll) == "function" and tonumber(scroll:GetVerticalScroll()) or 0
    local maximum = type(scroll.GetVerticalScrollRange) == "function" and tonumber(scroll:GetVerticalScrollRange()) or 0
    local child = type(scroll.GetScrollChild) == "function" and scroll:GetScrollChild() or nil
    local childHeight = child and type(child.GetHeight) == "function" and tonumber(child:GetHeight()) or 0
    local viewHeight = type(scroll.GetHeight) == "function" and tonumber(scroll:GetHeight()) or 0
    maximum = math.max(tonumber(maximum) or 0, math.max(0, childHeight - viewHeight))
    local target = clamp((current or 0) - (tonumber(delta) or 0) * (tonumber(step) or 42), 0, math.max(0, maximum or 0))
    scroll:SetVerticalScroll(target)
    local bar = scroll.ScrollBar or scroll.scrollBar
    if bar and type(bar.SetValue) == "function" then pcall(bar.SetValue, bar, target) end
end

local function bindMouseWheel(frame, scroll, step)
    if not frame or type(frame.EnableMouseWheel) ~= "function" or type(frame.SetScript) ~= "function" then return end
    if type(frame.EnableMouse) == "function" then frame:EnableMouse(true) end
    frame:EnableMouseWheel(true)
    frame:SetScript("OnMouseWheel", function(_, delta) scrollFrameByWheel(scroll, delta, step) end)
end

local function showSimpleTooltip(owner, title, body)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:AddLine(tostring(title or ""), 1, 1, 1)
    if body and body ~= "" then GameTooltip:AddLine(tostring(body), 0.72, 0.74, 0.78, true) end
    GameTooltip:Show()
end

local function normalizeName(value)
    value = trim(value)
    local base = string.match(value, "^([^%-]+)") or value
    return lower(base)
end

local function classColor(class)
    local key = upper(class)
    local colors = _G.CUSTOM_CLASS_COLORS or _G.RAID_CLASS_COLORS
    local c = colors and colors[key] or nil
    if c then return c.r or 1, c.g or 1, c.b or 1 end
    return 0.90, 0.90, 0.90
end

function BotInspect:InitializeSettings()
    local db
    if E and type(E.db) == "table" then
        E.db.multibotBotInspect = type(E.db.multibotBotInspect) == "table" and E.db.multibotBotInspect or {}
        db = E.db.multibotBotInspect
    else
        db = self.db or {}
    end
    for key, value in pairs(DEFAULTS) do if db[key] == nil then db[key] = value end end
    db.scale = clamp(db.scale, 0.70, 1.50)
    db.itemSize = math.floor(clamp(db.itemSize, 26, 38))
    db.inventoryColumns = math.floor(clamp(db.inventoryColumns, 8, 11))
    if db.rosterExpanded == nil then db.rosterExpanded = true end
    db.groupPresets = type(db.groupPresets) == "table" and db.groupPresets or {}
    if db.activeGroupPreset ~= nil and type(db.activeGroupPreset) ~= "string" then db.activeGroupPreset = nil end
    -- Alpha3.3 used a temporary BotInspect-only hidden roster. Core 1.4 now owns true Forget,
    -- so migrate that presentation workaround away rather than preserving a second identity list.
    db.hiddenRosterBots = nil
    self.db = db
    return db
end

function BotInspect:GetSettings()
    if E and type(E.db) == "table" then
        if type(E.db.multibotBotInspect) ~= "table" or E.db.multibotBotInspect ~= self.db then return self:InitializeSettings() end
    end
    return self.db or self:InitializeSettings()
end

function BotInspect:OnElvUIProfileChanged()
    self.db = nil
    self:InitializeSettings()
    if not self.frame then return end
    self:ApplySettings()
    self:ApplyRosterExpanded()
    self:RefreshBotList()
    self:RenderAll()
end

function BotInspect:RegisterElvUIProfileCallbacks()
    if self.profileCallbacksRegistered then return true end
    local data = E and E.data
    if not data or type(data.RegisterCallback) ~= "function" then
        return false, "ELVUI_PROFILE_CALLBACKS_UNAVAILABLE"
    end
    data.RegisterCallback(self, "OnProfileChanged", "OnElvUIProfileChanged")
    data.RegisterCallback(self, "OnProfileCopied", "OnElvUIProfileChanged")
    data.RegisterCallback(self, "OnProfileReset", "OnElvUIProfileChanged")
    self.profileCallbacksRegistered = true
    return true
end

function BotInspect:SavePosition()
    if not self.frame then return end
    local point, _, relativePoint, x, y = self.frame:GetPoint(1)
    if not point then return end
    local db = self:GetSettings()
    db.point, db.relativePoint, db.x, db.y = point, relativePoint or point, tonumber(x) or 0, tonumber(y) or 0
end

function BotInspect:ApplyPosition()
    if not self.frame then return end
    local db = self:GetSettings()
    self.frame:ClearAllPoints()
    self.frame:SetPoint(db.point or "CENTER", UIParent, db.relativePoint or "CENTER", tonumber(db.x) or 0, tonumber(db.y) or 0)
end

function BotInspect:ApplyRosterExpanded()
    if not self.frame then return end
    local expanded = self:GetSettings().rosterExpanded ~= false
    local roster = self.frame.rosterPanel
    if expanded then
        self.frame:SetWidth(MAIN_WIDTH + HANDLE_WIDTH + ROSTER_WIDTH)
        if roster then roster:Show() end
        if self.frame.rosterHandle and self.frame.rosterHandle.label then self.frame.rosterHandle.label:SetText("<") end
    else
        self.frame:SetWidth(MAIN_WIDTH + HANDLE_WIDTH)
        if roster then roster:Hide() end
        if self.frame.rosterHandle and self.frame.rosterHandle.label then self.frame.rosterHandle.label:SetText(">") end
    end
end

function BotInspect:ApplySettings()
    local db = self:GetSettings()
    if self.frame then
        self.frame:SetScale(db.scale or 1)
        self:ApplyRosterExpanded()
        self:ApplyPosition()
    end
    if self.frame and self.frame:IsShown() then self:RenderInventory() end
    if type(self.RefreshMicroBarButton) == "function" then self:RefreshMicroBarButton() end
    if type(self.RefreshHotkeyBinding) == "function" then self:RefreshHotkeyBinding() end
end

function BotInspect:SetStatus(text, r, g, b)
    if not self.frame or not self.frame.status then return end
    self.frame.status:SetText(tostring(text or ""))
    self.frame.status:SetTextColor(r or 0.70, g or 0.72, b or 0.76)
end

function BotInspect:GetSelectedManagedRecord()
    if not self.selectedBot or type(API.GetManagedBot) ~= "function" then return nil end
    return API:GetManagedBot(self.selectedBot)
end

function BotInspect:GetSelectedBotRecord()
    if not self.selectedBot then return nil end
    return API:GetBot(self.selectedBot)
end

function BotInspect:SelectedBotKey()
    local bot = self:GetSelectedBotRecord()
    if bot and bot.key then return tostring(bot.key) end
    return self.selectedBot and lower(self.selectedBot) or nil
end

function BotInspect:IsSelectedTarget(targetKey)
    local selected = self:SelectedBotKey()
    if not selected or not targetKey then return false end
    return lower(targetKey) == lower(selected)
end

function BotInspect:IsBotOnline(botRef)
    local managed = type(API.GetManagedBot) == "function" and API:GetManagedBot(botRef) or nil
    if managed then
        if managed.online == true then return true end
        return upper(managed.effectiveState) == "ONLINE"
    end
    local bot = API:GetBot(botRef)
    return bot and bot.online == true or false
end

function BotInspect:IsSelectedBotOnline()
    return self.selectedBot and self:IsBotOnline(self.selectedBot) or false
end

function BotInspect:GetDisplayDomain(domainId)
    if not self.selectedBot then return nil, { status = "MISSING", error = "BOT_REQUIRED" }, "NONE" end
    if self:IsSelectedBotOnline() then
        local value, meta = API:Get(domainId, self.selectedBot)
        if value ~= nil then return value, meta, "LIVE" end
        -- A live on-demand read may be temporarily unavailable (especially native
        -- Inspect). Show retained data while the reliability controller obtains a
        -- fresh observation instead of rendering an empty panel.
        local historical, historicalMeta = API:GetLastKnown(domainId, self.selectedBot)
        if historical ~= nil then return historical, historicalMeta, "HISTORICAL_FALLBACK" end
        return nil, meta or { status = "MISSING" }, "LIVE_PENDING"
    end
    local value, meta = API:GetLastKnown(domainId, self.selectedBot)
    return value, meta, "HISTORICAL"
end

function BotInspect:GetBotDisplayProfile(botRef)
    if not botRef then return "--", "--", nil, nil end
    local live = self:IsBotOnline(botRef)
    local detail
    if live then
        detail = select(1, API:Get("BOT.DETAIL", botRef))
        if not detail then detail = select(1, API:GetLastKnown("BOT.DETAIL", botRef)) end
    else detail = select(1, API:GetLastKnown("BOT.DETAIL", botRef)) end
    detail = type(detail) == "table" and detail or {}

    local spec, role
    if live then
        local sv = safeCall(API, "GetBotSpec", botRef)
        local rv = safeCall(API, "GetBotRole", botRef)
        if type(sv) == "table" and sv.state == "CONFIRMED" then spec = sv.primary or sv.spec end
        if type(rv) == "table" and rv.primary and rv.primary ~= "UNKNOWN" then role = rv.primary end
    end

    local class = classKey(detail.className or detail.class)
    local tree = dominantTreeFromDetail(detail)
    if not spec and tree and SPEC_CATALOG[class] then spec = SPEC_CATALOG[class][tree] end
    if not role and tree then role = roleForTree(class, tree) end
    if not role and (class == "MAGE" or class == "WARLOCK" or class == "HUNTER" or class == "ROGUE") then role = "DPS" end

    return spec or "--", role or "--", tonumber(detail.score), detail
end

local function localNow()
    if type(GetTime) == "function" then return tonumber(GetTime()) or 0 end
    return 0
end

function BotInspect:EnsureScheduler()
    if self.schedulerFrame then return self.schedulerFrame end
    local frame = CreateFrame("Frame")
    frame:Hide()
    frame:SetScript("OnUpdate", function()
        local jobs = BotInspect.scheduledJobs or {}
        local now = localNow()
        local due = {}
        for key, job in pairs(jobs) do
            if type(job) == "table" and now >= (tonumber(job.at) or 0) then due[#due + 1] = key end
        end
        for _, key in ipairs(due) do
            local job = jobs[key]
            jobs[key] = nil
            if job and type(job.fn) == "function" then pcall(job.fn) end
        end
        if next(jobs) == nil then frame:Hide() end
    end)
    self.schedulerFrame = frame
    return frame
end

function BotInspect:ScheduleLocal(key, delay, fn)
    if not key or type(fn) ~= "function" then return end
    self.scheduledJobs = self.scheduledJobs or {}
    self.scheduledJobs[tostring(key)] = { at = localNow() + math.max(0, tonumber(delay) or 0), fn = fn }
    self:EnsureScheduler():Show()
end

function BotInspect:CancelLocal(key)
    if self.scheduledJobs then self.scheduledJobs[tostring(key or "")] = nil end
end

function BotInspect:BackgroundWorkAllowed()
    if self.bulkLifecycleRunning then return false end
    return localNow() >= (tonumber(self.backgroundResumeAt) or 0)
end

function BotInspect:DeferBackgroundWork(delay)
    delay = math.max(0, tonumber(delay) or 0)
    self.backgroundResumeAt = math.max(tonumber(self.backgroundResumeAt) or 0, localNow() + delay)
    self:ScheduleLocal("background-resume", delay, function()
        if not BotInspect:BackgroundWorkAllowed() then
            local remaining = math.max(0.05, (tonumber(BotInspect.backgroundResumeAt) or 0) - localNow())
            BotInspect:DeferBackgroundWork(remaining)
            return
        end
        BotInspect:PumpAutoResolveQueue()
        BotInspect:PumpHistoryPrimeQueue()
        BotInspect:ScheduleRosterRefresh(0)
        BotInspect:ScheduleSelectedEnsure(0.25, false)
    end)
end

function BotInspect:ScheduleRosterRefresh(delay)
    self:ScheduleLocal("ui-roster-refresh", delay == nil and UI_EVENT_COALESCE_DELAY or delay, function()
        if BotInspect.frame and BotInspect.frame.rosterPanel then BotInspect:RefreshRoster() end
    end)
end

function BotInspect:ScheduleFullRefresh(delay)
    self:ScheduleLocal("ui-full-refresh", delay == nil and UI_EVENT_COALESCE_DELAY or delay, function()
        BotInspect:RefreshBotList()
    end)
end

function BotInspect:GetLastKnownDomainEntries(botRef, fresh)
    local key = normalizeName(type(botRef) == "table" and botRef.name or botRef)
    if not fresh and key ~= "" and self.lastKnownSummaryCache and self.lastKnownSummaryCache[key] then
        return self.lastKnownSummaryCache[key]
    end
    local list = type(API.GetLastKnownDomains) == "function" and (API:GetLastKnownDomains(botRef) or {}) or {}
    if not fresh and key ~= "" then
        self.lastKnownSummaryCache = self.lastKnownSummaryCache or {}
        self.lastKnownSummaryCache[key] = list
    end
    return list
end

function BotInspect:GetLastKnownDomainSet(botRef, fresh)
    local set = {}
    for _, entry in ipairs(self:GetLastKnownDomainEntries(botRef, fresh)) do
        if type(entry) == "table" and entry.domain then set[entry.domain] = true end
    end
    return set
end

function BotInspect:ResetHistoryPrimeState()
    self.historyPrimeQueue = {}
    self.historyPrimeQueued = {}
    self.historyPrimeAttempted = {}
    self.historyPrimeCompleted = {}
    self.historyPrimeRetryAt = {}
    self.historyPrimeActiveBots = {}
    self.historyPrimeActive = 0
end

function BotInspect:ResetHistoryPrimeBot(botRef)
    local key = normalizeName(type(botRef) == "table" and botRef.name or botRef)
    if key == "" then return end
    self.historyPrimeAttempted[key] = nil
    self.historyPrimeCompleted[key] = nil
    self.historyPrimeRetryAt[key] = nil
    self.historyPrimeQueued[key] = nil
    self.historyPrimeActiveBots[key] = nil
    self:CancelLocal("history-requeue-" .. key)
end

function BotInspect:LiveDomainReady(botRef, domainId)
    if type(API.GetMeta) ~= "function" then return false end
    local meta = API:GetMeta(domainId, botRef)
    if type(meta) ~= "table" then return false end
    if meta.stale == true or meta.available == false or meta.status == "ERROR" or meta.error then return false end
    return true
end

function BotInspect:GetHistoryPrimeCompleted(botRef)
    local key = normalizeName(type(botRef) == "table" and botRef.name or botRef)
    if key == "" then return {} end
    self.historyPrimeCompleted[key] = self.historyPrimeCompleted[key] or {}
    local completed = self.historyPrimeCompleted[key]
    -- Reuse any canonical live data another subscriber/Core path already obtained.
    -- GetMeta is intentionally used here so roster passes do not deep-copy large
    -- inventory/equipment values merely to test their presence.
    for _, domainId in ipairs(HISTORY_PRIME_DOMAINS) do
        if not completed[domainId] and self:LiveDomainReady(botRef, domainId) then completed[domainId] = true end
    end
    return completed
end

function BotInspect:BotNeedsHistoryPrime(bot)
    if type(bot) ~= "table" or bot.online ~= true or bot.managed ~= true or not bot.name then return false end
    local completed = self:GetHistoryPrimeCompleted(bot.name)
    for _, domainId in ipairs(HISTORY_PRIME_DOMAINS) do
        if not completed[domainId] then return true end
    end
    return false
end

function BotInspect:PrimeBotHistory(botName, finished)
    local key = normalizeName(botName)
    local completed = self:GetHistoryPrimeCompleted(botName)
    local missing = {}
    for _, domainId in ipairs(HISTORY_PRIME_DOMAINS) do
        if not completed[domainId] then missing[#missing + 1] = domainId end
    end
    local index = 1
    local errors = {}
    local function finish()
        local remaining = {}
        completed = BotInspect:GetHistoryPrimeCompleted(botName)
        for _, domainId in ipairs(HISTORY_PRIME_DOMAINS) do
            if not completed[domainId] then remaining[#remaining + 1] = domainId end
        end
        if type(finished) == "function" then finished({ remaining = remaining, errors = errors }) end
    end
    local function nextDomain()
        if not BotInspect:BackgroundWorkAllowed() then
            BotInspect:ScheduleLocal("history-domain-" .. key, 0.25, nextDomain)
            return
        end
        local domainId = missing[index]
        index = index + 1
        if not domainId then finish(); return end

        -- Avoid knowingly dispatching an Inspect request while the unit is not yet
        -- inspectable. This is a transient condition and will be retried later.
        if domainId == "BOT.EQUIPMENT" and type(API.GetEquipmentObservationAvailability) == "function" then
            local availability = API:GetEquipmentObservationAvailability(botName)
            if not availability or availability.enabled ~= true then
                errors[domainId] = availability and availability.reason or "EQUIPMENT_UNAVAILABLE"
                BotInspect:ScheduleLocal("history-domain-" .. key, HISTORY_DOMAIN_GAP, nextDomain)
                return
            end
        end

        local readId, err = API:Refresh(domainId, botName, function(value, meta)
            if value ~= nil and not (meta and meta.status == "ERROR") then
                completed[domainId] = true
            else
                errors[domainId] = meta and meta.error or "READ_FAILED"
            end
            BotInspect:ScheduleLocal("history-domain-" .. key, HISTORY_DOMAIN_GAP, nextDomain)
        end)
        if not readId then
            errors[domainId] = err or "READ_UNAVAILABLE"
            BotInspect:ScheduleLocal("history-domain-" .. key, HISTORY_DOMAIN_GAP, nextDomain)
        end
    end
    nextDomain()
end

function BotInspect:QueueHistoryPrimeBotByName(botName)
    if not botName or not self:BackgroundWorkAllowed() then return end
    local bots = self:GetSelectableBots()
    for _, bot in ipairs(bots) do
        if normalizeName(bot.name) == normalizeName(botName) then
            self:QueueHistoryPrimeBots({ bot })
            return
        end
    end
end

function BotInspect:PumpHistoryPrimeQueue()
    if not self:BackgroundWorkAllowed() then return end
    local concurrency = tonumber(self.historyPrimeConcurrency) or 1
    while (tonumber(self.historyPrimeActive) or 0) < concurrency and #(self.historyPrimeQueue or {}) > 0 do
        local name = table.remove(self.historyPrimeQueue, 1)
        local key = normalizeName(name)
        self.historyPrimeQueued[key] = nil
        self.historyPrimeActiveBots[key] = true
        self.historyPrimeAttempted[key] = (tonumber(self.historyPrimeAttempted[key]) or 0) + 1
        local pass = self.historyPrimeAttempted[key]
        self.historyPrimeActive = (tonumber(self.historyPrimeActive) or 0) + 1
        self:PrimeBotHistory(name, function(result)
            BotInspect.historyPrimeActiveBots[key] = nil
            BotInspect.historyPrimeActive = math.max(0, (tonumber(BotInspect.historyPrimeActive) or 1) - 1)
            BotInspect:ScheduleRosterRefresh(UI_EVENT_COALESCE_DELAY)
            local remaining = result and result.remaining or {}
            if #remaining > 0 and BotInspect:IsBotOnline(name) and pass < HISTORY_PRIME_MAX_PASSES then
                local delay = HISTORY_RETRY_DELAYS[math.min(pass, #HISTORY_RETRY_DELAYS)] or 30
                BotInspect.historyPrimeRetryAt[key] = localNow() + delay
                BotInspect:ScheduleLocal("history-requeue-" .. key, delay, function()
                    BotInspect:QueueHistoryPrimeBotByName(name)
                end)
            else
                BotInspect.historyPrimeRetryAt[key] = nil
            end
            BotInspect:ScheduleLocal("history-pump", HISTORY_BOT_GAP, function() BotInspect:PumpHistoryPrimeQueue() end)
        end)
    end
end

function BotInspect:QueueHistoryPrimeBots(bots)
    if not self:BackgroundWorkAllowed() then return end
    local now = localNow()
    for _, bot in ipairs(bots or {}) do
        local key = bot.name and normalizeName(bot.name) or ""
        local attempts = tonumber(self.historyPrimeAttempted[key]) or 0
        local retryAt = tonumber(self.historyPrimeRetryAt[key]) or 0
        if key ~= "" and not self.historyPrimeActiveBots[key] and not self.historyPrimeQueued[key]
            and attempts < HISTORY_PRIME_MAX_PASSES and now >= retryAt and self:BotNeedsHistoryPrime(bot) then
            self.historyPrimeQueued[key] = true
            self.historyPrimeQueue[#self.historyPrimeQueue + 1] = bot.name
        end
    end
    if #(self.historyPrimeQueue or {}) > 0 then
        self:ScheduleLocal("history-pump", HISTORY_PRIME_START_DELAY, function() BotInspect:PumpHistoryPrimeQueue() end)
    end
end

-- Selected-bot reliability --------------------------------------------------

function BotInspect:IsSelectedDomainWanted(domainId)
    local domains = self.activeView == "QUESTS" and {} or (self.activeView == "SPELLBOOK" and SELECTED_SPELLBOOK_DOMAINS or SELECTED_GEAR_DOMAINS)
    for _, wanted in ipairs(domains) do if wanted == domainId then return true end end
    return false
end

function BotInspect:SelectedRetryKey(domainId)
    return normalizeName(self.selectedBot) .. "|" .. tostring(domainId or "")
end

function BotInspect:CancelSelectedReliabilityJobs()
    self.selectedEnsureGeneration = (tonumber(self.selectedEnsureGeneration) or 0) + 1
    self.selectedRetryAttempts = {}
    for key in pairs(self.scheduledJobs or {}) do
        if string.sub(tostring(key), 1, 9) == "selected-" then self.scheduledJobs[key] = nil end
    end
end

function BotInspect:ScheduleSelectedDomainRetry(domainId, errorCode)
    if not RELIABLE_DOMAIN[domainId] or not self:IsSelectedDomainWanted(domainId) or not self.selectedBot or not self:IsSelectedBotOnline() then return end
    if not self.frame or not self.frame:IsShown() then return end
    local jobKey = "selected-retry-" .. tostring(domainId)
    if self.scheduledJobs and self.scheduledJobs[jobKey] then return end
    local retryKey = self:SelectedRetryKey(domainId)
    local attempts = (tonumber(self.selectedRetryAttempts[retryKey]) or 0) + 1
    self.selectedRetryAttempts[retryKey] = attempts
    local delay = SELECTED_RETRY_DELAYS[math.min(attempts, #SELECTED_RETRY_DELAYS)] or 20
    if errorCode == "BOT_UNIT_UNAVAILABLE" or errorCode == "BOT_NOT_VISIBLE" or errorCode == "BOT_NOT_INSPECTABLE" or errorCode == "INSPECT_CONTEXT_BUSY" then
        delay = math.max(delay, 2.0)
    end
    local generation = self.selectedEnsureGeneration
    self:ScheduleLocal(jobKey, delay, function()
        if generation ~= BotInspect.selectedEnsureGeneration then return end
        BotInspect:RefreshSelectedDomain(domainId, false)
    end)
end

function BotInspect:RefreshSelectedDomain(domainId, force)
    if not RELIABLE_DOMAIN[domainId] or not self:IsSelectedDomainWanted(domainId) or not self.selectedBot or not self:IsSelectedBotOnline() then return end
    if not self.frame or not self.frame:IsShown() then return end
    if not self:BackgroundWorkAllowed() then
        self:ScheduleSelectedDomainRetry(domainId, "BACKGROUND_DEFERRED")
        return
    end
    local botName = self.selectedBot
    local retryKey = self:SelectedRetryKey(domainId)
    if not force and self:LiveDomainReady(botName, domainId) then
        self.selectedRetryAttempts[retryKey] = nil
        return
    end
    if domainId == "BOT.EQUIPMENT" and type(API.GetEquipmentObservationAvailability) == "function" then
        local availability = API:GetEquipmentObservationAvailability(botName)
        if not availability or availability.enabled ~= true then
            self:ScheduleSelectedDomainRetry(domainId, availability and availability.reason or "EQUIPMENT_UNAVAILABLE")
            return
        end
    end
    local readId, err = API:Refresh(domainId, botName, function(value, meta)
        if BotInspect.selectedBot ~= botName then return end
        if value ~= nil and not (meta and meta.status == "ERROR") then
            BotInspect.selectedRetryAttempts[retryKey] = nil
            BotInspect:ScheduleFullRefresh(UI_EVENT_COALESCE_DELAY)
        else
            BotInspect:ScheduleSelectedDomainRetry(domainId, meta and meta.error or "READ_FAILED")
        end
    end)
    if not readId then self:ScheduleSelectedDomainRetry(domainId, err or "READ_UNAVAILABLE") end
end

function BotInspect:EnsureSelectedData(force)
    if not self.selectedBot or not self:IsSelectedBotOnline() or not self.frame or not self.frame:IsShown() then return end
    local generation = self.selectedEnsureGeneration
    local domains = self.activeView == "QUESTS" and {} or (self.activeView == "SPELLBOOK" and SELECTED_SPELLBOOK_DOMAINS or SELECTED_GEAR_DOMAINS)
    for index, domainId in ipairs(domains) do
        self:ScheduleLocal("selected-kick-" .. tostring(domainId), (index - 1) * SELECTED_DOMAIN_GAP, function()
            if generation ~= BotInspect.selectedEnsureGeneration then return end
            BotInspect:RefreshSelectedDomain(domainId, force == true)
        end)
    end
end

function BotInspect:ScheduleSelectedEnsure(delay, force)
    local generation = self.selectedEnsureGeneration
    self:ScheduleLocal("selected-ensure", delay == nil and SELECTED_ENSURE_START_DELAY or delay, function()
        if generation ~= BotInspect.selectedEnsureGeneration then return end
        BotInspect:EnsureSelectedData(force == true)
    end)
end

function BotInspect:Acquire(domain)
    if not self.selectedBot or self.interests[domain] == self.selectedBot then return end
    if self.interests[domain] then API:Release(MODULE, domain, self.interests[domain]) end
    API:Acquire(MODULE, domain, self.selectedBot)
    self.interests[domain] = self.selectedBot
end

function BotInspect:Release(domain)
    local target = self.interests[domain]
    if not target then return end
    API:Release(MODULE, domain, target)
    self.interests[domain] = nil
end

function BotInspect:ReleaseAllInterests()
    local list = {}
    for domain in pairs(self.interests) do list[#list + 1] = domain end
    for _, domain in ipairs(list) do self:Release(domain) end
end

function BotInspect:UpdateInterests()
    if not self.frame or not self.frame:IsShown() or not self.selectedBot then
        self:ReleaseAllInterests()
        return
    end
    if not self:IsSelectedBotOnline() then
        self:ReleaseAllInterests()
        return
    end
    self:Acquire("BOT.DETAIL")
    self:Acquire("BOT.STATS")
    if self.activeView == "QUESTS" then
        self:Release("BOT.SPELLBOOK")
        self:Release("BOT.EQUIPMENT")
        self:Release("BOT.INVENTORY_EXACT")
        self:Release("BOT.INVENTORY")
    elseif self.activeView == "SPELLBOOK" then
        self:Acquire("BOT.SPELLBOOK")
        self:Release("BOT.EQUIPMENT")
        self:Release("BOT.INVENTORY_EXACT")
        self:Release("BOT.INVENTORY")
    else
        self:Acquire("BOT.EQUIPMENT")
        self:Acquire("BOT.INVENTORY_EXACT")
        self:Acquire("BOT.INVENTORY")
        self:Release("BOT.SPELLBOOK")
    end
end

function BotInspect:RefreshAll()
    if not self.selectedBot then return end
    if not self:IsSelectedBotOnline() then
        self:SetStatus("Offline: showing Core last-known history; no live refresh dispatched.", 0.95, 0.72, 0.30)
        self:RenderAll()
        return
    end
    if self.activeView == "QUESTS" and type(self.RefreshSelectedQuests) == "function" then
        self:RefreshSelectedQuests(true)
        return
    end
    self:SetStatus("Refreshing " .. tostring(self.selectedBot) .. " with reliable paced reads...")
    self:CancelSelectedReliabilityJobs()
    self:EnsureSelectedData(true)
end

function BotInspect:GetSelectableBots()
    local result, byName = {}, {}
    local view = type(API.GetManagedRosterView) == "function" and API:GetManagedRosterView() or nil
    for _, managed in ipairs(view and view.items or {}) do
        if managed.name then
            local live = API:GetBot(managed.name) or {}
            local item = {
                name = managed.name,
                guid = tonumber(managed.guid) or tonumber(live.guid or live.altGuid),
                class = live.className or live.class or managed.className or managed.class,
                level = tonumber(live.level) or tonumber(managed.level),
                online = live.online == true or managed.online == true or upper(managed.effectiveState) == "ONLINE",
                effectiveState = managed.effectiveState,
                managed = true,
                liveRegistry = live.online == true,
            }
            result[#result + 1] = item
            byName[normalizeName(item.name)] = item
        end
    end

    -- BRIDGE.ROSTER is the immediate current-session presence source. Linked-account
    -- Playerbots can be live here before Core has learned their stable GUID, so expose
    -- them immediately and let the bounded resolver queue persist them through Core.
    local liveBots = type(API.GetBots) == "function" and API:GetBots({ online = true }) or {}
    for _, live in ipairs(liveBots or {}) do
        if live and live.name and live.online == true then
            local key = normalizeName(live.name)
            local item = byName[key]
            if item then
                item.online = true
                item.liveRegistry = true
                item.guid = item.guid or tonumber(live.guid or live.altGuid)
                item.class = live.className or live.class or item.class
                item.level = tonumber(live.level) or item.level
                item.effectiveState = "ONLINE"
            else
                item = {
                    name = live.name,
                    guid = tonumber(live.guid or live.altGuid),
                    class = live.className or live.class,
                    level = tonumber(live.level),
                    online = true,
                    effectiveState = "ONLINE",
                    managed = false,
                    liveRegistry = true,
                }
                result[#result + 1] = item
                byName[key] = item
            end
        end
    end

    table.sort(result, function(a, b)
        if a.online ~= b.online then return a.online end
        return tostring(a.name or "") < tostring(b.name or "")
    end)
    return result
end

function BotInspect:IsSelectableBot(botRef)
    local wanted = normalizeName(type(botRef) == "table" and botRef.name or botRef)
    if wanted == "" then return nil end
    for _, bot in ipairs(self:GetSelectableBots()) do
        if normalizeName(bot.name) == wanted then return bot end
    end
    return nil
end

function BotInspect:ResetAutoResolveState()
    self.autoResolveQueue = {}
    self.autoResolveQueued = {}
    self.autoResolveAttempted = {}
    self.autoResolveActive = 0
end

function BotInspect:PumpAutoResolveQueue()
    if type(API.ResolveBotTarget) ~= "function" or not self:BackgroundWorkAllowed() then return end
    local concurrency = tonumber(self.autoResolveConcurrency) or 1
    while (tonumber(self.autoResolveActive) or 0) < concurrency and #(self.autoResolveQueue or {}) > 0 do
        local name = table.remove(self.autoResolveQueue, 1)
        local key = normalizeName(name)
        self.autoResolveQueued[key] = nil
        if API:GetManagedBot(name) then
            self.autoResolveAttempted[key] = true
        else
            self.autoResolveAttempted[key] = true
            self.autoResolveActive = (tonumber(self.autoResolveActive) or 0) + 1
            local readId, err = API:ResolveBotTarget(name, function(value, meta)
                BotInspect.autoResolveActive = math.max(0, (tonumber(BotInspect.autoResolveActive) or 1) - 1)
                -- Successful resolution is persisted by Core and emits MB_MANAGED_ROSTER_UPDATED.
                -- A terminal refusal is attempted once per bridge session; manual Discover remains available.
                if meta and meta.status == "ERROR" and (meta.error == "BRIDGE_NOT_CONNECTED" or meta.error == "BRIDGE_NOT_READY") then
                    BotInspect.autoResolveAttempted[key] = nil
                end
                BotInspect:ScheduleRosterRefresh(UI_EVENT_COALESCE_DELAY)
                BotInspect:ScheduleLocal("auto-resolve-pump", AUTO_RESOLVE_START_DELAY, function() BotInspect:PumpAutoResolveQueue() end)
            end)
            if not readId then
                self.autoResolveActive = math.max(0, (tonumber(self.autoResolveActive) or 1) - 1)
                if err == "BRIDGE_NOT_CONNECTED" or err == "BRIDGE_NOT_READY" then self.autoResolveAttempted[key] = nil end
            end
        end
    end
end

function BotInspect:QueueAutoResolveUnmanagedLiveBots(bots)
    if not self:BackgroundWorkAllowed() then return end
    for _, bot in ipairs(bots or {}) do
        if bot.online == true and bot.managed ~= true and bot.name then
            local key = normalizeName(bot.name)
            if key ~= "" and not self.autoResolveAttempted[key] and not self.autoResolveQueued[key] then
                self.autoResolveQueued[key] = true
                self.autoResolveQueue[#self.autoResolveQueue + 1] = bot.name
            end
        end
    end
    if #(self.autoResolveQueue or {}) > 0 then
        self:ScheduleLocal("auto-resolve-pump", AUTO_RESOLVE_START_DELAY, function() BotInspect:PumpAutoResolveQueue() end)
    end
end

function BotInspect:ChooseDefaultBot()
    local current = self.selectedBot and self:IsSelectableBot(self.selectedBot) or nil
    if current then return current.name end
    local bots = self:GetSelectableBots()
    for _, bot in ipairs(bots) do if bot.online then return bot.name end end
    return bots[1] and bots[1].name or nil
end

function BotInspect:SelectBot(botRef)
    local managed = type(API.GetManagedBot) == "function" and API:GetManagedBot(botRef) or nil
    local bot = API:ResolveBot(botRef)
    local name = managed and managed.name or (bot and bot.online == true and bot.name) or nil
    if not name then return false, "BOT_UNAVAILABLE" end
    if type(self.CancelInventoryDrag) == "function" then self:CancelInventoryDrag(true) end
    self:ReleaseAllInterests()
    self:CancelSelectedReliabilityJobs()
    self.selectedBot = name
    self:UpdateInterests()
    self:RenderAll()
    self:ScheduleSelectedEnsure(SELECTED_ENSURE_START_DELAY, false)
    if self.activeView == "SPELLBOOK" and self.frame and self.frame:IsShown() and self:IsSelectedBotOnline() and type(self.RequestSpellIgnoredList) == "function" then
        self:RequestSpellIgnoredList(name)
    elseif self.activeView == "QUESTS" and self.frame and self.frame:IsShown() and type(self.RefreshSelectedQuests) == "function" then
        self:RefreshSelectedQuests(true)
    end
    return true
end

function BotInspect:DiscoverBot(name, selectOnSuccess)
    name = trim(name)
    if name == "" then return nil, "BOT_NAME_REQUIRED" end
    if type(API.ResolveBotTarget) ~= "function" then return nil, "TARGET_RESOLVE_UNAVAILABLE" end
    self:SetStatus("Discovering " .. name .. " through Core target resolve...")
    local readId, err = API:ResolveBotTarget(name, function(value, meta)
        if meta and meta.status == "ERROR" then
            BotInspect:SetStatus("Discovery failed: " .. tostring(meta.error or "TARGET_RESOLVE_FAILED"), 1, 0.45, 0.35)
            return
        end
        if type(value) ~= "table" or upper(value.status) ~= "OK" then
            BotInspect:SetStatus("Discovery failed: " .. tostring(type(value) == "table" and value.reason or "TARGET_NOT_FOUND"), 1, 0.45, 0.35)
            return
        end
        local canonical = value.name or name
        BotInspect:RefreshRoster()
        if selectOnSuccess ~= false then BotInspect:SelectBot(canonical) end
        if BotInspect.frame and BotInspect.frame.rosterSearch then BotInspect.frame.rosterSearch:SetText("") end
        BotInspect:SetStatus("Discovered managed bot " .. tostring(canonical) .. ".", 0.35, 0.90, 0.50)
    end)
    if not readId then self:SetStatus("Discovery unavailable: " .. tostring(err or "TARGET_RESOLVE_FAILED"), 1, 0.45, 0.35) end
    return readId, err
end

function BotInspect:ForgetRosterBot(bot)
    if type(bot) ~= "table" or not bot.name then return false, "BOT_REQUIRED" end
    if type(API.GetForgetManagedBotAvailability) ~= "function" or type(API.ForgetManagedBot) ~= "function" then
        self:SetStatus("Forget unavailable: Core managed-forget API missing.", 1, 0.45, 0.35)
        return false, "FORGET_API_UNAVAILABLE"
    end
    local ref = { name = bot.name, guid = tonumber(bot.guid) }
    local availability = API:GetForgetManagedBotAvailability(ref)
    if not availability or availability.enabled ~= true then
        self:SetStatus("Forget unavailable for " .. tostring(bot.name) .. ": " .. tostring(availability and availability.reason or "MANAGED_BOT_NOT_FOUND"), 1, 0.55, 0.35)
        return false, availability and availability.reason or "MANAGED_BOT_NOT_FOUND"
    end
    local result = API:ForgetManagedBot(MODULE, ref, {})
    if type(result) ~= "table" or result.ok ~= true then
        self:SetStatus("Forget failed for " .. tostring(bot.name) .. ": " .. tostring(result and (result.code or result.status) or "UNKNOWN"), 1, 0.45, 0.35)
        return false, result and (result.code or result.status) or "FORGET_FAILED"
    end
    if self.selectedBot and normalizeName(self.selectedBot) == normalizeName(bot.name) then
        self:ReleaseAllInterests()
        self.selectedBot = nil
    end
    self.rosterOffset = 0
    self:RefreshBotList()
    local cleanup = result.cleanup or {}
    self:SetStatus(string.format("Forgot %s from Core (history %d, snapshots %d, groups %d).", tostring(bot.name), tonumber(cleanup.lastKnown) or 0, tonumber(cleanup.snapshots) or 0, tonumber(cleanup.groups) or 0), 0.35, 0.90, 0.50)
    return true
end

function BotInspect:ConfirmForgetRosterBot(bot)
    if type(bot) ~= "table" or not bot.name or bot.managed ~= true then return end
    local popup = type(StaticPopup_Show) == "function" and StaticPopup_Show("ELVUI_MULTIBOT_BOTINSPECT_FORGET_ROSTER", tostring(bot.name)) or nil
    if popup then popup.data = { bot = bot } end
end

function BotInspect:GetLatestHistoricalObservedAt(botRef)
    local latest = 0
    if type(API.GetLastKnownDomains) ~= "function" then return nil end
    local domains = self:GetLastKnownDomainEntries(botRef)
    for _, entry in ipairs(domains) do
        local stamp = entry and entry.meta and tonumber(entry.meta.observedAt) or 0
        if stamp > latest then latest = stamp end
    end
    return latest > 0 and latest or nil
end

local function sortedPresetNames(presets)
    local names = {}
    for name, preset in pairs(type(presets) == "table" and presets or {}) do
        if type(name) == "string" and trim(name) ~= "" and type(preset) == "table" then names[#names + 1] = name end
    end
    table.sort(names, function(a, b) return lower(a) < lower(b) end)
    return names
end

function BotInspect:GetGroupPresets()
    local db = self:GetSettings()
    db.groupPresets = type(db.groupPresets) == "table" and db.groupPresets or {}
    return db.groupPresets
end

function BotInspect:FindGroupPresetName(name)
    local wanted = lower(trim(name))
    if wanted == "" then return nil end
    for presetName in pairs(self:GetGroupPresets()) do
        if lower(trim(presetName)) == wanted then return presetName end
    end
    return nil
end

function BotInspect:GetActiveGroupPreset()
    local db = self:GetSettings()
    local name = self:FindGroupPresetName(db.activeGroupPreset)
    if not name then
        db.activeGroupPreset = nil
        return nil, nil
    end
    db.activeGroupPreset = name
    return name, self:GetGroupPresets()[name]
end

function BotInspect:SetActiveGroupPreset(name)
    local db = self:GetSettings()
    local canonical = self:FindGroupPresetName(name)
    db.activeGroupPreset = canonical
    self:RefreshPresetControls()
    self:RenderRosterWindow()
    return canonical ~= nil
end

function BotInspect:NormalizePresetMembers(members)
    local result, seen = {}, {}
    for _, value in ipairs(type(members) == "table" and members or {}) do
        local name = trim(type(value) == "table" and value.name or value)
        local key = normalizeName(name)
        if key ~= "" and not seen[key] then
            seen[key] = true
            result[#result + 1] = name
        end
    end
    return result
end

function BotInspect:CollectCurrentGroupBots()
    local result, seen = {}, {}
    local function addUnit(unit)
        if type(UnitExists) == "function" and not UnitExists(unit) then return end
        local name = type(UnitName) == "function" and UnitName(unit) or nil
        if not name or normalizeName(name) == normalizeName(type(UnitName) == "function" and UnitName("player") or "") then return end
        local managed = type(API.GetManagedBot) == "function" and API:GetManagedBot(name) or nil
        local live = type(API.GetBot) == "function" and API:GetBot(name) or nil
        if not managed and not (live and live.online == true) then return end
        local canonical = (managed and managed.name) or (live and live.name) or name
        local key = normalizeName(canonical)
        if key ~= "" and not seen[key] then seen[key] = true; result[#result + 1] = canonical end
    end

    local raidCount = type(GetNumRaidMembers) == "function" and (tonumber(GetNumRaidMembers()) or 0) or 0
    if raidCount > 0 then
        for i = 1, raidCount do addUnit("raid" .. i) end
    else
        local partyCount = type(GetNumPartyMembers) == "function" and (tonumber(GetNumPartyMembers()) or 0) or 0
        for i = 1, partyCount do addUnit("party" .. i) end
    end
    return result
end

function BotInspect:SaveGroupPreset(name, members)
    name = trim(name)
    if name == "" then self:SetStatus("Preset name is required.", 1, 0.55, 0.35); return false, "PRESET_NAME_REQUIRED" end
    local presets = self:GetGroupPresets()
    local existing = self:FindGroupPresetName(name)
    local targetName = existing or name
    local normalized = self:NormalizePresetMembers(members)
    presets[targetName] = presets[targetName] or {}
    presets[targetName].members = normalized
    presets[targetName].updatedAt = type(time) == "function" and time() or nil
    self:GetSettings().activeGroupPreset = targetName
    self:RefreshPresetControls()
    self:RenderRosterWindow()
    self:SetStatus(string.format("%s preset %s with %d bot%s.", existing and "Updated" or "Saved", targetName, #normalized, #normalized == 1 and "" or "s"), 0.35, 0.90, 0.50)
    return true, targetName
end

function BotInspect:RenameGroupPreset(oldName, newName)
    local oldCanonical = self:FindGroupPresetName(oldName)
    newName = trim(newName)
    if not oldCanonical then return false, "PRESET_NOT_FOUND" end
    if newName == "" then self:SetStatus("Preset name is required.", 1, 0.55, 0.35); return false, "PRESET_NAME_REQUIRED" end
    local collision = self:FindGroupPresetName(newName)
    if collision and collision ~= oldCanonical then
        self:SetStatus("A preset named " .. tostring(collision) .. " already exists.", 1, 0.55, 0.35)
        return false, "PRESET_EXISTS"
    end
    if newName == oldCanonical then return true, oldCanonical end
    local presets = self:GetGroupPresets()
    presets[newName] = presets[oldCanonical]
    presets[oldCanonical] = nil
    self:GetSettings().activeGroupPreset = newName
    self:RefreshPresetControls()
    self:SetStatus("Renamed preset " .. tostring(oldCanonical) .. " to " .. tostring(newName) .. ".", 0.35, 0.90, 0.50)
    return true, newName
end

function BotInspect:DeleteGroupPreset(name)
    local canonical = self:FindGroupPresetName(name)
    if not canonical then return false, "PRESET_NOT_FOUND" end
    self:GetGroupPresets()[canonical] = nil
    local db = self:GetSettings()
    if lower(trim(db.activeGroupPreset)) == lower(canonical) then db.activeGroupPreset = nil end
    self:RefreshPresetControls()
    self:RenderRosterWindow()
    self:SetStatus("Deleted preset " .. tostring(canonical) .. ".", 0.95, 0.72, 0.30)
    return true
end

function BotInspect:IsBotInGroupPreset(botName, preset)
    local wanted = normalizeName(botName)
    for _, member in ipairs(type(preset) == "table" and type(preset.members) == "table" and preset.members or {}) do
        if normalizeName(member) == wanted then return true end
    end
    return false
end

function BotInspect:ToggleActivePresetMember(botName)
    local presetName, preset = self:GetActiveGroupPreset()
    if not presetName or not preset then
        self:SetStatus("Select or save a group preset first.", 0.95, 0.72, 0.30)
        return false, "NO_ACTIVE_PRESET"
    end
    local members = self:NormalizePresetMembers(preset.members)
    local wanted = normalizeName(botName)
    local nextMembers, removed = {}, false
    for _, member in ipairs(members) do
        if normalizeName(member) == wanted then removed = true else nextMembers[#nextMembers + 1] = member end
    end
    if not removed then nextMembers[#nextMembers + 1] = tostring(botName) end
    preset.members = nextMembers
    preset.updatedAt = type(time) == "function" and time() or nil
    self:RefreshPresetControls()
    self:RenderRosterWindow()
    self:SetStatus(string.format("%s %s %s %s.", removed and "Removed" or "Added", tostring(botName), removed and "from" or "to", tostring(presetName)), 0.45, 0.82, 1.0)
    return true
end

function BotInspect:ReplaceActivePresetFromCurrentGroup()
    local presetName = self:GetActiveGroupPreset()
    if not presetName then self:SetStatus("Select a group preset first.", 0.95, 0.72, 0.30); return false end
    return self:SaveGroupPreset(presetName, self:CollectCurrentGroupBots())
end

function BotInspect:ClearActivePresetMembers()
    local presetName, preset = self:GetActiveGroupPreset()
    if not presetName or not preset then return false end
    preset.members = {}
    preset.updatedAt = type(time) == "function" and time() or nil
    self:RefreshPresetControls(); self:RenderRosterWindow()
    self:SetStatus("Cleared members from preset " .. tostring(presetName) .. ". Ctrl+click roster bots to rebuild it.", 0.95, 0.72, 0.30)
    return true
end

function BotInspect:ShowSaveGroupPresetPopup()
    local members = self:CollectCurrentGroupBots()
    local activeName = self:GetActiveGroupPreset()
    local popup = type(StaticPopup_Show) == "function" and StaticPopup_Show("ELVUI_MULTIBOT_BOTINSPECT_SAVE_GROUP_PRESET") or nil
    if popup then
        popup.data = { members = members, initialName = activeName or "" }
        if popup.editBox then popup.editBox:SetText(tostring(activeName or "")); popup.editBox:HighlightText(); popup.editBox:SetFocus() end
    end
end

function BotInspect:ShowRenameGroupPresetPopup()
    local activeName = self:GetActiveGroupPreset()
    if not activeName then return end
    local popup = type(StaticPopup_Show) == "function" and StaticPopup_Show("ELVUI_MULTIBOT_BOTINSPECT_RENAME_GROUP_PRESET", tostring(activeName)) or nil
    if popup then
        popup.data = { oldName = activeName, initialName = activeName }
        if popup.editBox then popup.editBox:SetText(tostring(activeName)); popup.editBox:HighlightText(); popup.editBox:SetFocus() end
    end
end

function BotInspect:ConfirmDeleteGroupPreset()
    local activeName = self:GetActiveGroupPreset()
    if not activeName then return end
    local popup = type(StaticPopup_Show) == "function" and StaticPopup_Show("ELVUI_MULTIBOT_BOTINSPECT_DELETE_GROUP_PRESET", tostring(activeName)) or nil
    if popup then popup.data = { name = activeName } end
end

function BotInspect:SendSummonWhisper(botName)
    if type(SendChatMessage) ~= "function" then return false, "CHAT_API_UNAVAILABLE" end
    SendChatMessage("summon", "WHISPER", nil, botName)
    return true
end

function BotInspect:FinishPresetSummonMember(state, botName, ok)
    if self.presetSummonState ~= state then return end
    state.done = state.done + 1
    if ok then state.summoned = state.summoned + 1 else state.failed = state.failed + 1 end
    if state.done < state.total then return end
    self.presetSummonRunning = false
    self.presetSummonState = nil
    self:DeferBackgroundWork(BACKGROUND_SETTLE_DELAY)
    self:ScheduleFullRefresh(UI_EVENT_COALESCE_DELAY)
    self:RefreshPresetControls()
    self:SetStatus(string.format("Preset %s complete: %d summoned, %d failed/skipped.", tostring(state.name), state.summoned, state.failed), state.failed == 0 and 0.35 or 1, state.failed == 0 and 0.90 or 0.70, state.failed == 0 and 0.50 or 0.30)
end

function BotInspect:WaitForPresetBotOnline(state, botName, attempt)
    if self.presetSummonState ~= state then return end
    attempt = tonumber(attempt) or 1
    if self:IsBotOnline(botName) then
        local ok = self:SendSummonWhisper(botName)
        self:FinishPresetSummonMember(state, botName, ok == true)
        return
    end
    local delays = { 0.35, 0.75, 1.25, 2.0, 3.0, 4.0 }
    local delay = delays[attempt]
    if not delay then self:FinishPresetSummonMember(state, botName, false); return end
    self:ScheduleLocal("preset-summon-wait-" .. normalizeName(botName), delay, function()
        BotInspect:WaitForPresetBotOnline(state, botName, attempt + 1)
    end)
end

function BotInspect:SummonGroupPreset(name)
    local canonical = self:FindGroupPresetName(name)
    local preset = canonical and self:GetGroupPresets()[canonical] or nil
    local members = preset and self:NormalizePresetMembers(preset.members) or {}
    if not canonical or not preset then self:SetStatus("Select a saved group preset first.", 0.95, 0.72, 0.30); return false, "PRESET_NOT_FOUND" end
    if #members == 0 then self:SetStatus("Preset " .. tostring(canonical) .. " has no members. Ctrl+click roster bots to add them.", 0.95, 0.72, 0.30); return false, "PRESET_EMPTY" end
    if self.bulkLifecycleRunning or self.presetSummonRunning then
        self:SetStatus("Preset summon unavailable while another bulk lifecycle operation is running.", 0.95, 0.72, 0.30)
        return false, "LIFECYCLE_BUSY"
    end

    local state = { name = canonical, total = #members, done = 0, summoned = 0, failed = 0, connectQueue = {}, nextIndex = 1, active = 0 }
    self.presetSummonRunning = true
    self.presetSummonState = state
    self:CancelLocal("history-pump"); self:CancelLocal("auto-resolve-pump"); self:CancelLocal("preset-summon-pump")
    self:RefreshPresetControls()

    for _, botName in ipairs(members) do
        if self:IsBotOnline(botName) then
            local ok = self:SendSummonWhisper(botName)
            self:FinishPresetSummonMember(state, botName, ok == true)
        else
            local managed = type(API.GetManagedBot) == "function" and API:GetManagedBot(botName) or nil
            local availability = managed and type(API.GetManagedBotLifecycleAvailability) == "function" and API:GetManagedBotLifecycleAvailability(botName, "CONNECT") or nil
            if managed and availability and availability.enabled == true and not self.lifecyclePending[botName] then
                state.connectQueue[#state.connectQueue + 1] = botName
            else
                self:FinishPresetSummonMember(state, botName, false)
            end
        end
    end
    if self.presetSummonState ~= state then return true end

    local launchNext
    launchNext = function()
        if BotInspect.presetSummonState ~= state then return end
        while state.active < BULK_LIFECYCLE_CONCURRENCY and state.nextIndex <= #state.connectQueue do
            local botName = state.connectQueue[state.nextIndex]
            state.nextIndex = state.nextIndex + 1
            state.active = state.active + 1
            BotInspect.lifecyclePending[botName] = true
            local requestId = API:RequestBotLifecycle(MODULE, botName, "CONNECT", function(result)
                BotInspect.lifecyclePending[botName] = nil
                state.active = math.max(0, state.active - 1)
                if result and result.ok == true then BotInspect:WaitForPresetBotOnline(state, botName, 1)
                else BotInspect:FinishPresetSummonMember(state, botName, false) end
                BotInspect:ScheduleRosterRefresh(UI_EVENT_COALESCE_DELAY)
                if BotInspect.presetSummonState == state and state.nextIndex <= #state.connectQueue then
                    BotInspect:ScheduleLocal("preset-summon-pump", BULK_LIFECYCLE_BATCH_GAP, launchNext)
                end
            end)
            if not requestId then
                BotInspect.lifecyclePending[botName] = nil
                state.active = math.max(0, state.active - 1)
                BotInspect:FinishPresetSummonMember(state, botName, false)
            end
        end
    end

    self:SetStatus(string.format("Summoning preset %s: %d bot%s; offline members will connect first...", canonical, #members, #members == 1 and "" or "s"), 0.45, 0.82, 1.0)
    launchNext()
    return true
end

function BotInspect:RefreshPresetControls()
    local panel = self.frame and self.frame.rosterPanel
    if not panel then return end
    local name, preset = self:GetActiveGroupPreset()
    local count = preset and #self:NormalizePresetMembers(preset.members) or 0
    if panel.presetSelect and panel.presetSelect.label then
        local text = name and (tostring(name) .. " (" .. tostring(count) .. ")") or "No preset"
        panel.presetSelect.label:SetText(text)
    end
    setButtonEnabled(panel.presetSummon, name ~= nil and count > 0 and not self.presetSummonRunning and not self.bulkLifecycleRunning)
    setButtonEnabled(panel.presetActions, name ~= nil and not self.presetSummonRunning)
end

function BotInspect:BuildPresetSelectMenu()
    if self.presetSelectMenu then return self.presetSelectMenu end
    local menu = CreateFrame("Frame", "ElvUI_Multibot_BotInspectPresetSelectMenu", UIParent, "UIDropDownMenuTemplate")
    self.presetSelectMenu = menu
    UIDropDownMenu_Initialize(menu, function(_, level)
        level = level or 1
        if level ~= 1 then return end
        local activeName = BotInspect:GetActiveGroupPreset()
        local names = sortedPresetNames(BotInspect:GetGroupPresets())
        local title = UIDropDownMenu_CreateInfo(); title.text = "Summon Presets"; title.isTitle = true; title.notCheckable = true; UIDropDownMenu_AddButton(title, level)
        if #names == 0 then
            local empty = UIDropDownMenu_CreateInfo(); empty.text = "No saved presets"; empty.disabled = true; empty.notCheckable = true; UIDropDownMenu_AddButton(empty, level)
        else
            for _, name in ipairs(names) do
                local preset = BotInspect:GetGroupPresets()[name]
                local info = UIDropDownMenu_CreateInfo()
                info.text = tostring(name) .. " (" .. tostring(#BotInspect:NormalizePresetMembers(preset.members)) .. ")"
                info.checked = activeName == name
                info.func = function() BotInspect:SetActiveGroupPreset(name) end
                UIDropDownMenu_AddButton(info, level)
            end
        end
    end, "MENU")
    return menu
end

function BotInspect:BuildPresetActionsMenu()
    if self.presetActionsMenu then return self.presetActionsMenu end
    local menu = CreateFrame("Frame", "ElvUI_Multibot_BotInspectPresetActionsMenu", UIParent, "UIDropDownMenuTemplate")
    self.presetActionsMenu = menu
    UIDropDownMenu_Initialize(menu, function(_, level)
        level = level or 1
        if level ~= 1 then return end
        local activeName = BotInspect:GetActiveGroupPreset()
        local title = UIDropDownMenu_CreateInfo(); title.text = activeName and ("Preset: " .. tostring(activeName)) or "No active preset"; title.isTitle = true; title.notCheckable = true; UIDropDownMenu_AddButton(title, level)
        if not activeName then return end
        local defs = {
            { "Rename", function() BotInspect:ShowRenameGroupPresetPopup() end },
            { "Replace with current group", function() BotInspect:ReplaceActivePresetFromCurrentGroup() end },
            { "Clear members", function() BotInspect:ClearActivePresetMembers() end },
            { "Delete preset", function() BotInspect:ConfirmDeleteGroupPreset() end },
        }
        for _, def in ipairs(defs) do
            local info = UIDropDownMenu_CreateInfo(); info.text = def[1]; info.notCheckable = true; info.func = def[2]; UIDropDownMenu_AddButton(info, level)
        end
    end, "MENU")
    return menu
end

function BotInspect:RequestLifecycle(botName)
    if not botName or self.lifecyclePending[botName] then return end
    local online = self:IsBotOnline(botName)
    local action = online and "DISCONNECT" or "CONNECT"
    local availability = type(API.GetManagedBotLifecycleAvailability) == "function" and API:GetManagedBotLifecycleAvailability(botName, action) or nil
    if not availability or availability.enabled ~= true then
        self:SetStatus(string.format("%s unavailable for %s: %s", action, tostring(botName), tostring(availability and availability.reason or "LIFECYCLE_UNAVAILABLE")), 1, 0.55, 0.35)
        return
    end
    self.lifecyclePending[botName] = true
    self:RefreshRoster()
    local requestId, err = API:RequestBotLifecycle(MODULE, botName, action, function(result)
        BotInspect.lifecyclePending[botName] = nil
        BotInspect:ScheduleFullRefresh(UI_EVENT_COALESCE_DELAY)
        local ok = result and result.ok == true
        BotInspect:SetStatus(string.format("%s %s: %s", action, tostring(botName), tostring(result and (result.code or result.status) or "UNKNOWN")), ok and 0.35 or 1, ok and 0.90 or 0.55, ok and 0.50 or 0.35)
    end)
    if not requestId then
        self.lifecyclePending[botName] = nil
        self:ScheduleRosterRefresh(UI_EVENT_COALESCE_DELAY)
        self:SetStatus(string.format("%s failed for %s: %s", action, tostring(botName), tostring(err or "LIFECYCLE_DISPATCH_FAILED")), 1, 0.45, 0.35)
    else
        self:SetStatus(string.format("%s requested for %s...", action, tostring(botName)))
    end
end

function BotInspect:SummonBot(botName)
    if not botName then return end
    if not self:IsBotOnline(botName) then
        self:SetStatus("Summon requires an online bot. Connect " .. tostring(botName) .. " first.", 0.95, 0.72, 0.30)
        return
    end
    -- Core 1.5 has no SUMMON semantic. This is intentionally a feature-coverage
    -- Playerbots chat path, not a fallback behind Core lifecycle/bridge failure.
    if type(SendChatMessage) ~= "function" then
        self:SetStatus("Summon unavailable: chat API unavailable.", 1, 0.45, 0.35)
        return
    end
    self:SendSummonWhisper(botName)
    self:SetStatus("Summon sent to " .. tostring(botName) .. ".", 0.45, 0.82, 1.0)
end

function BotInspect:RunLifecycleAll(action)
    action = upper(action)
    if action ~= "CONNECT" and action ~= "DISCONNECT" then return end
    local label = action == "CONNECT" and "Connect All" or "Disconnect All"
    if self.bulkLifecycleRunning then
        self:SetStatus(label .. " unavailable while another bulk lifecycle operation is running.", 0.95, 0.72, 0.30)
        return
    end

    local queue = {}
    for _, bot in ipairs(self:GetSelectableBots()) do
        local wants = (action == "CONNECT" and not bot.online) or (action == "DISCONNECT" and bot.online)
        if wants and bot.managed == true and not self.lifecyclePending[bot.name] then
            local availability = type(API.GetManagedBotLifecycleAvailability) == "function" and API:GetManagedBotLifecycleAvailability(bot.name, action) or nil
            if availability and availability.enabled == true then queue[#queue + 1] = bot.name end
        end
    end
    if #queue == 0 then
        self:SetStatus(label .. ": no eligible managed bots.", 0.95, 0.72, 0.30)
        return
    end

    self.bulkLifecycleRunning = true
    self.bulkLifecycleAction = action
    self:CancelLocal("history-pump")
    self:CancelLocal("auto-resolve-pump")
    self:CancelLocal("bulk-lifecycle-pump")
    local state = { queue = queue, nextIndex = 1, active = 0, done = 0, ok = 0, failed = 0, total = #queue, action = action, label = label }
    self.bulkLifecycleState = state

    local launchNext
    local function finishIfDone()
        if state.done < state.total then return false end
        BotInspect.bulkLifecycleRunning = false
        BotInspect.bulkLifecycleAction = nil
        BotInspect.bulkLifecycleState = nil
        BotInspect:DeferBackgroundWork(BACKGROUND_SETTLE_DELAY)
        BotInspect:ScheduleFullRefresh(UI_EVENT_COALESCE_DELAY)
        BotInspect:SetStatus(string.format("%s complete: %d succeeded, %d failed/skipped. Background inspection will resume after the roster settles.", label, state.ok, state.failed), state.failed == 0 and 0.35 or 1, state.failed == 0 and 0.90 or 0.70, state.failed == 0 and 0.50 or 0.30)
        return true
    end

    launchNext = function()
        if finishIfDone() then return end
        local launched = 0
        while state.active < BULK_LIFECYCLE_CONCURRENCY and state.nextIndex <= state.total and launched < BULK_LIFECYCLE_CONCURRENCY do
            local botName = state.queue[state.nextIndex]
            state.nextIndex = state.nextIndex + 1
            state.active = state.active + 1
            launched = launched + 1
            BotInspect.lifecyclePending[botName] = true
            local requestId, err = API:RequestBotLifecycle(MODULE, botName, action, function(result)
                BotInspect.lifecyclePending[botName] = nil
                state.active = math.max(0, state.active - 1)
                state.done = state.done + 1
                if result and result.ok == true then state.ok = state.ok + 1 else state.failed = state.failed + 1 end
                BotInspect:ScheduleRosterRefresh(UI_EVENT_COALESCE_DELAY)
                if not finishIfDone() then BotInspect:ScheduleLocal("bulk-lifecycle-pump", BULK_LIFECYCLE_BATCH_GAP, launchNext) end
            end)
            if not requestId then
                BotInspect.lifecyclePending[botName] = nil
                state.active = math.max(0, state.active - 1)
                state.done = state.done + 1
                state.failed = state.failed + 1
                BotInspect:ScheduleLocal("bulk-lifecycle-pump", BULK_LIFECYCLE_BATCH_GAP, launchNext)
                break
            end
        end
        BotInspect:ScheduleRosterRefresh(UI_EVENT_COALESCE_DELAY)
        if not finishIfDone() and state.active == 0 and state.nextIndex > state.total then
            while state.done < state.total do state.done = state.done + 1; state.failed = state.failed + 1 end
            finishIfDone()
        end
    end

    self:SetStatus(string.format("%s: processing %d managed bots in paced batches; background inspection is paused...", label, state.total), 0.45, 0.82, 1.0)
    launchNext()
end

function BotInspect:ConnectAll() self:RunLifecycleAll("CONNECT") end
function BotInspect:DisconnectAll() self:RunLifecycleAll("DISCONNECT") end

local function findUnitForName(name)
    if type(UnitName) ~= "function" then return nil end
    local wanted = normalizeName(name)
    local units = { "target", "mouseover", "focus" }
    for i = 1, 4 do units[#units + 1] = "party" .. i end
    for i = 1, 40 do units[#units + 1] = "raid" .. i end
    for _, unit in ipairs(units) do
        local exists = type(UnitExists) ~= "function" or UnitExists(unit)
        if exists then
            local n = UnitName(unit)
            if n and normalizeName(n) == wanted then return unit end
        end
    end
    return nil
end

local function buildFlatItemLookup(flatView)
    local out = {}
    for _, item in ipairs(flatView and flatView.items or {}) do
        local id = tonumber(item.itemId)
        if id and not out[id] then out[id] = item end
    end
    return out
end

local function bagLabel(descriptor)
    local kind = tostring(descriptor.kind or "BAG")
    local bag = tonumber(descriptor.bag) or 0
    if kind == "BACKPACK" then return "Backpack" end
    if kind == "KEYRING" then return "Keyring" end
    if descriptor.itemId and tonumber(descriptor.itemId) and tonumber(descriptor.itemId) > 0 and type(GetItemInfo) == "function" then
        local name = GetItemInfo(tonumber(descriptor.itemId))
        if name then return tostring(name) end
    end
    return "Bag " .. tostring(bag)
end

local function matchesInventoryFilter(filter, flatItem)
    if filter == FILTER_ALL then return true end
    flatItem = flatItem or {}
    local t = lower(flatItem.type)
    local st = lower(flatItem.subType)
    local equipLoc = trim(flatItem.equipLoc)
    if filter == FILTER_GEAR then
        return flatItem.equipCandidate == true or equipLoc ~= ""
    elseif filter == FILTER_QUEST then
        return string.find(t, "quest", 1, true) ~= nil or string.find(st, "quest", 1, true) ~= nil
    elseif filter == FILTER_CONSUMABLES then
        if string.find(t, "consumable", 1, true) then return true end
        local words = { "potion", "elixir", "flask", "food", "drink", "bandage", "scroll", "consumable" }
        for _, word in ipairs(words) do if string.find(st, word, 1, true) then return true end end
    end
    return false
end

function BotInspect:EquipmentButtonEnter(button)
    if not button then return end
    GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
    local slot = button.data
    if slot and slot.itemLink then
        GameTooltip:SetHyperlink(slot.itemLink)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(string.format("%s  -  server slot %d", SLOT_SHORT[slot.slotName] or slot.slotName or "Equipment", tonumber(slot.serverSlot) or 0), 0.55, 0.75, 1.0)
        if button.historical then GameTooltip:AddLine("Historical equipment observation - read only.", 0.95, 0.72, 0.30)
        else GameTooltip:AddLine("Shift+Right-click for BotInspect actions.", 0.55, 0.82, 1.0) end
    else
        local descriptor = button.descriptor or {}
        GameTooltip:AddLine(SLOT_SHORT[descriptor.slotName] or descriptor.slotName or "Equipment Slot", 1, 1, 1)
        GameTooltip:AddLine("Empty or not observed.", 0.62, 0.62, 0.66)
    end
    GameTooltip:Show()
end

local function findInventoryDropButton(frame)
    local current = frame
    for _ = 1, 8 do
        if not current then break end
        if current.botInspectInventorySlot then return current end
        current = type(current.GetParent) == "function" and current:GetParent() or nil
    end
    return nil
end

function BotInspect:GetInventoryDragFrame()
    if self.inventoryDragFrame then return self.inventoryDragFrame end
    local frame = CreateFrame("Frame", "ElvUI_Multibot_BotInspectInventoryDragFrame", UIParent)
    frame:SetWidth(36); frame:SetHeight(36)
    frame:SetFrameStrata("TOOLTIP")
    frame:EnableMouse(false)
    createBackdrop(frame, 0.92)
    local icon = frame:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", frame, "TOPLEFT", 2, -2)
    icon:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 2)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    frame.icon = icon
    local count = createText(frame, 9, "RIGHT")
    count:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 1)
    frame.countText = count
    frame:SetScript("OnUpdate", function(self)
        if not BotInspect.inventoryDrag then self:Hide(); return end
        if type(GetCursorPosition) == "function" then
            local x, y = GetCursorPosition()
            local scale = UIParent and type(UIParent.GetEffectiveScale) == "function" and UIParent:GetEffectiveScale() or 1
            if not scale or scale <= 0 then scale = 1 end
            self:ClearAllPoints()
            self:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x / scale + 18, y / scale - 18)
        end
        if type(IsMouseButtonDown) == "function" and not IsMouseButtonDown("LeftButton") then
            local focus = type(GetMouseFocus) == "function" and GetMouseFocus() or nil
            BotInspect:CompleteInventoryDrag(findInventoryDropButton(focus))
        end
    end)
    frame:Hide()
    self.inventoryDragFrame = frame
    return frame
end

function BotInspect:CancelInventoryDrag(silent)
    local drag = self.inventoryDrag
    self.inventoryDrag = nil
    local frame = self.inventoryDragFrame
    if frame then frame:Hide() end
    if drag and drag.sourceButton then
        local sourceButton = drag.sourceButton
        self:ScheduleLocal("inventory-drag-click-suppress-" .. tostring(sourceButton), 0.05, function() sourceButton.botInspectSuppressClick = nil end)
    end
    if drag and not silent then self:SetStatus("Inventory move cancelled.", 0.65, 0.68, 0.72) end
end

function BotInspect:BeginInventoryDrag(button)
    if not button or not button.item or button.historical or self.inventoryMovePending then return end
    if not self.selectedBot or not self:IsSelectedBotOnline() then return end
    local selector = button.actionSelector or button.item
    local bag, slot = tonumber(selector and selector.bag), tonumber(selector and selector.slot)
    if bag == nil or slot == nil then return end
    self:CancelInventoryDrag(true)
    button.botInspectSuppressClick = true
    self.inventoryDrag = {
        botName = self.selectedBot,
        sourceBag = bag,
        sourceSlot = slot,
        itemId = tonumber(selector.itemId),
        count = tonumber(selector.count) or 1,
        itemName = button.itemName or (selector.itemId and ("Item " .. tostring(selector.itemId))) or "Item",
        icon = button.icon and button.icon:GetTexture() or nil,
        sourceButton = button,
    }
    local frame = self:GetInventoryDragFrame()
    frame.icon:SetTexture(self.inventoryDrag.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    frame.countText:SetText(self.inventoryDrag.count > 1 and tostring(self.inventoryDrag.count) or "")
    frame:Show()
    self:SetStatus("Drag " .. tostring(self.inventoryDrag.itemName) .. " onto another bag slot to move or swap it.", 0.45, 0.82, 1.0)
end

function BotInspect:CompleteInventoryDrag(targetButton)
    local drag = self.inventoryDrag
    if not drag then return end
    -- Clear visual state before any Core call. The source data remains guarded by Core.
    self.inventoryDrag = nil
    if self.inventoryDragFrame then self.inventoryDragFrame:Hide() end
    if drag.sourceButton then
        local sourceButton = drag.sourceButton
        self:ScheduleLocal("inventory-drag-click-suppress-" .. tostring(sourceButton), 0.05, function() sourceButton.botInspectSuppressClick = nil end)
    end

    if not targetButton or not targetButton.botInspectInventorySlot then
        self:SetStatus("Inventory move cancelled.", 0.65, 0.68, 0.72)
        return
    end
    if drag.botName ~= self.selectedBot or not self:IsSelectedBotOnline() or targetButton.historical then
        self:SetStatus("Inventory move unavailable: bot state changed.", 1, 0.55, 0.35)
        return
    end
    local dstBag, dstSlot = tonumber(targetButton.inventoryBag), tonumber(targetButton.inventorySlot)
    if dstBag == nil or dstSlot == nil then
        self:SetStatus("Inventory move unavailable: invalid destination slot.", 1, 0.55, 0.35)
        return
    end
    if dstBag == drag.sourceBag and dstSlot == drag.sourceSlot then
        self:SetStatus("Inventory item left in its original slot.", 0.65, 0.68, 0.72)
        return
    end
    if type(API.GetInventoryMoveAvailability) ~= "function" or type(API.ExecuteInventoryMove) ~= "function" then
        self:SetStatus("Inventory move unavailable: Core ITEM.MOVE API missing.", 1, 0.45, 0.35)
        return
    end
    local availability = API:GetInventoryMoveAvailability(drag.botName, drag.sourceBag, drag.sourceSlot, dstBag, dstSlot)
    if not availability or availability.enabled ~= true then
        self:SetStatus("Inventory move unavailable: " .. tostring(availability and availability.reason or "UNKNOWN"), 1, 0.45, 0.35)
        return
    end
    local swapping = availability.destination ~= nil
    self.inventoryMovePending = true
    self:SetStatus((swapping and "Swapping " or "Moving ") .. tostring(drag.itemName) .. "...", 0.45, 0.82, 1.0)
    local txId, err = API:ExecuteInventoryMove(MODULE, drag.botName, drag.sourceBag, drag.sourceSlot, dstBag, dstSlot, function(tx)
        BotInspect.inventoryMovePending = false
        local state = type(tx) == "table" and tx.state or nil
        if state == "CONFIRMED" or state == "SUCCEEDED" or state == "COMPLETED" then
            BotInspect:SetStatus((swapping and "Swapped " or "Moved ") .. tostring(drag.itemName) .. ".", 0.35, 0.85, 0.60)
        else
            local reason = type(tx) == "table" and (tx.error or (tx.result and tx.result.reason) or tx.state) or "ITEM_MOVE_FAILED"
            BotInspect:SetStatus("Inventory move failed: " .. tostring(reason or "UNKNOWN"), 1, 0.45, 0.35)
        end
        if BotInspect.selectedBot == drag.botName then BotInspect:ScheduleSelectedEnsure(0.20, false) end
    end)
    if not txId then
        self.inventoryMovePending = false
        self:SetStatus("Inventory move unavailable: " .. tostring(err or "UNKNOWN"), 1, 0.45, 0.35)
    end
end

function BotInspect:InventoryButtonEnter(button)
    if BotInspect.inventoryDrag and button and button.botInspectInventorySlot then
        GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
        GameTooltip:ClearLines()
        local item = button.item
        GameTooltip:AddLine(item and "Swap with this slot" or "Move to this slot", 0.35, 0.82, 1.0)
        GameTooltip:AddLine(string.format("Bag %s  -  Slot %s", tostring(button.inventoryBag or "?"), tostring(button.inventorySlot or "?")), 0.65, 0.68, 0.72)
        GameTooltip:Show()
        return
    end
    local item = button and button.item or nil
    if not item then return end
    GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
    if button.itemLink then GameTooltip:SetHyperlink(button.itemLink)
    else GameTooltip:AddLine(button.itemName or (item.itemId and ("Item " .. tostring(item.itemId))) or "Unknown item", 1, 1, 1) end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(string.format("Bag %s  -  Slot %s", tostring(item.bag or "?"), tostring(item.slot or "?")), 0.55, 0.75, 1.0)
    GameTooltip:AddLine("Count: " .. tostring(item.count or 1), 0.78, 0.78, 0.82)
    if item.soulbound then GameTooltip:AddLine("Soulbound", 0.95, 0.60, 0.25) end
    if button.historical then
        GameTooltip:AddLine("Historical physical position - read only.", 0.95, 0.72, 0.30)
    else
        GameTooltip:AddLine("Right-click: Equip", 0.55, 0.82, 1.0)
        GameTooltip:AddLine("Drag: Move / swap bag slots", 0.55, 0.82, 1.0)
        GameTooltip:AddLine("Shift+Right-click: actions menu", 0.55, 0.82, 1.0)
        local mode = BotInspect.defaultInventoryAction
        if mode then
            if mode == "DESTROY" then GameTooltip:AddLine("Left-click: DESTROY immediately", 1.0, 0.35, 0.25)
            else GameTooltip:AddLine("Left-click: " .. tostring(mode), 0.55, 0.82, 1.0) end
        end
    end
    GameTooltip:Show()
end

local function isMerchantWindowOpen()
    if not MerchantFrame then return false end
    if type(MerchantFrame.IsShown) == "function" then return MerchantFrame:IsShown() == 1 or MerchantFrame:IsShown() == true end
    if type(MerchantFrame.IsVisible) == "function" then return MerchantFrame:IsVisible() == 1 or MerchantFrame:IsVisible() == true end
    return false
end

function BotInspect:SetDefaultInventoryAction(action)
    action = action and upper(action) or nil
    if action ~= "SELL" and action ~= "GIVE" and action ~= "DESTROY" then action = nil end
    if action == "SELL" and not isMerchantWindowOpen() then
        self:SetStatus("Sell mode requires an open merchant window.", 0.95, 0.72, 0.30)
        action = nil
    end
    self.defaultInventoryAction = action
    self:RenderInventoryActionStrip()
end

function BotInspect:RenderInventoryActionStrip()
    local panel = self.frame and self.frame.inventoryPanel
    if not panel or not panel.actionButtons then return end
    if self.defaultInventoryAction == "SELL" and not isMerchantWindowOpen() then self.defaultInventoryAction = nil end
    local live = self:IsSelectedBotOnline()
    for action, button in pairs(panel.actionButtons) do
        local selected = (action == "NONE" and self.defaultInventoryAction == nil) or self.defaultInventoryAction == action
        if button.label then
            if selected then button.label:SetTextColor(0.25, 0.78, 1.0)
            else button.label:SetTextColor(0.86, 0.86, 0.88) end
        end
        local enabled = live
        if action == "NONE" then enabled = true end
        if action == "SELL" then enabled = live and isMerchantWindowOpen() end
        setButtonEnabled(button, enabled)
    end
    if panel.actionModeText then
        local mode = self.defaultInventoryAction or "None"
        if mode == "DESTROY" then
            panel.actionModeText:SetText("Left-click: DESTROY immediately")
            panel.actionModeText:SetTextColor(1.0, 0.35, 0.25)
        elseif mode == "SELL" then
            panel.actionModeText:SetText("Left-click: Sell to open merchant")
            panel.actionModeText:SetTextColor(0.95, 0.78, 0.25)
        elseif mode == "GIVE" then
            panel.actionModeText:SetText("Left-click: Give / trade to player")
            panel.actionModeText:SetTextColor(0.45, 0.82, 1.0)
        else
            panel.actionModeText:SetText("Left-click: no action")
            panel.actionModeText:SetTextColor(0.58, 0.62, 0.68)
        end
    end
end

function BotInspect:ExecuteDefaultInventoryClick(item)
    local action = self.defaultInventoryAction
    if not action or not item then return end
    if action == "SELL" and not isMerchantWindowOpen() then
        self:SetDefaultInventoryAction(nil)
        self:SetStatus("Sell mode cleared because the merchant window is not open.", 0.95, 0.72, 0.30)
        return
    end
    -- Selecting DESTROY mode is the user's explicit destructive intent. Core still
    -- receives confirmed=true and performs its normal availability/verification path.
    self:ExecuteInventoryAction(action, item, action == "DESTROY")
end

function BotInspect:GetInventoryActionOptions(item, confirmed)
    return {
        sourceBag = item and tonumber(item.bag) or nil,
        sourceSlot = item and tonumber(item.slot) or nil,
        confirmed = confirmed == true,
    }
end

function BotInspect:InventoryActionAvailability(action, item, confirmed)
    if not self.selectedBot or not self:IsSelectedBotOnline() then return { enabled = false, reason = "BOT_OFFLINE" } end
    if not item then return { enabled = false, reason = "ITEM_REQUIRED" } end
    return API:GetInventoryActionAvailability(self.selectedBot, action, item, self:GetInventoryActionOptions(item, confirmed))
end

function BotInspect:ExecuteInventoryAction(action, item, confirmed)
    if not item or not self.selectedBot or not self:IsSelectedBotOnline() then return end
    local txId, err = API:ExecuteInventoryAction(MODULE, self.selectedBot, action, item, self:GetInventoryActionOptions(item, confirmed), function(tx)
        local state = tx and (tx.state or tx.status or tx.error) or "UNKNOWN"
        BotInspect:SetStatus(string.format("%s: %s", action, tostring(state)), (tx and tx.state == "CONFIRMED") and 0.35 or 0.75, (tx and tx.state == "CONFIRMED") and 0.90 or 0.75, 0.50)
        BotInspect:RenderAll()
    end)
    if not txId then self:SetStatus(string.format("%s unavailable: %s", action, tostring(err or "INVENTORY_ACTION_UNAVAILABLE")), 1, 0.45, 0.35)
    else self:SetStatus(action .. " dispatched through Core...") end
end

function BotInspect:ExecuteUnequip(slot)
    if not slot or not self.selectedBot or not self:IsSelectedBotOnline() then return end
    local serverSlot = tonumber(slot.serverSlot)
    local itemId = tonumber(slot.itemId)
    local txId, err = API:ExecuteInventoryUnequip(MODULE, self.selectedBot, serverSlot, itemId, function(tx)
        BotInspect:SetStatus("UNEQUIP: " .. tostring(tx and (tx.state or tx.status or tx.error) or "UNKNOWN"))
        BotInspect:RenderAll()
    end)
    if not txId then self:SetStatus("UNEQUIP unavailable: " .. tostring(err or "ITEM_UNEQUIP_UNAVAILABLE"), 1, 0.45, 0.35)
    else self:SetStatus("UNEQUIP dispatched through Core...") end
end

function BotInspect:ConfirmDestroy(item)
    if not item then return end
    local name = item.name or item.itemName or (item.itemId and ("item " .. tostring(item.itemId))) or "this item"
    local popup = type(StaticPopup_Show) == "function" and StaticPopup_Show("ELVUI_MULTIBOT_BOTINSPECT_DESTROY", tostring(name)) or nil
    if popup then popup.data = { item = item } end
end

function BotInspect:BuildItemMenu()
    if self.itemMenu then return self.itemMenu end
    local menu = CreateFrame("Frame", "ElvUI_Multibot_BotInspectItemMenu", UIParent, "UIDropDownMenuTemplate")
    self.itemMenu = menu
    UIDropDownMenu_Initialize(menu, function(_, level)
        level = level or 1
        if level ~= 1 then return end
        local bot = BotInspect.selectedBot
        local live = bot and BotInspect:IsSelectedBotOnline()
        local item = BotInspect.contextItem
        local equip = BotInspect.contextEquipment

        local title = UIDropDownMenu_CreateInfo()
        title.text = "BotInspect Item"
        title.isTitle = true
        title.notCheckable = true
        UIDropDownMenu_AddButton(title, level)

        if not live then
            local info = UIDropDownMenu_CreateInfo()
            info.text = "Historical data - read only"
            info.disabled = true
            info.notCheckable = true
            UIDropDownMenu_AddButton(info, level)
            return
        end

        local function addAction(label, action)
            local availability = BotInspect:InventoryActionAvailability(action, item, action == "DESTROY")
            local info = UIDropDownMenu_CreateInfo()
            info.text = label
            info.notCheckable = true
            info.disabled = not availability or availability.enabled ~= true
            if info.disabled and availability and availability.reason then info.text = label .. " |cff777777(" .. tostring(availability.reason) .. ")|r" end
            info.func = function()
                if action == "DESTROY" then BotInspect:ConfirmDestroy(item)
                else BotInspect:ExecuteInventoryAction(action, item, false) end
            end
            UIDropDownMenu_AddButton(info, level)
        end

        if equip then
            local availability = API:GetInventoryUnequipAvailability(bot, tonumber(equip.serverSlot), tonumber(equip.itemId))
            local info = UIDropDownMenu_CreateInfo()
            info.text = "Unequip"
            info.notCheckable = true
            info.disabled = not availability or availability.enabled ~= true
            if info.disabled and availability and availability.reason then info.text = "Unequip |cff777777(" .. tostring(availability.reason) .. ")|r" end
            info.func = function() BotInspect:ExecuteUnequip(equip) end
            UIDropDownMenu_AddButton(info, level)
        elseif item then
            addAction("Equip", "EQUIP")
            addAction("Use", "USE")
            addAction("Trade / Give", "GIVE")
            addAction("Sell", "SELL")
            addAction("Destroy", "DESTROY")
        end
    end, "MENU")
    return menu
end

function BotInspect:OpenItemMenu(anchor, item, equipmentSlot)
    if type(IsShiftKeyDown) == "function" and not IsShiftKeyDown() then return end
    self.contextItem = item
    self.contextEquipment = equipmentSlot
    local menu = self:BuildItemMenu()
    if type(ToggleDropDownMenu) == "function" then ToggleDropDownMenu(1, nil, menu, anchor, 0, 0) end
end

function BotInspect:GetInventoryButton(index, parent)
    local button = self.inventoryButtons[index]
    if button then button:SetParent(parent); return button end
    button = CreateFrame("Button", nil, parent)
    createBackdrop(button, 0.78)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    button.botInspectInventorySlot = true
    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", button, "TOPLEFT", 2, -2)
    icon:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -2, 2)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    button.icon = icon
    local count = createText(button, 9, "RIGHT")
    count:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -2, 1)
    button.countText = count
    local soulbound = createText(button, 8, "LEFT")
    soulbound:SetPoint("TOPLEFT", button, "TOPLEFT", 2, -1)
    soulbound:SetTextColor(1.0, 0.64, 0.25)
    soulbound:SetText("S")
    button.soulboundText = soulbound
    button:SetScript("OnEnter", function(self) BotInspect:InventoryButtonEnter(self) end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    button:SetScript("OnDragStart", function(self) BotInspect:BeginInventoryDrag(self) end)
    button:SetScript("OnClick", function(self, mouseButton)
        if self.botInspectSuppressClick then return end
        if BotInspect.inventoryDrag then return end
        if not self.item or self.historical then return end
        if mouseButton == "RightButton" then
            if IsShiftKeyDown and IsShiftKeyDown() then
                BotInspect:OpenItemMenu(self, self.actionSelector or self.item, nil)
            else
                BotInspect:ExecuteInventoryAction("EQUIP", self.actionSelector or self.item, false)
            end
        elseif mouseButton == "LeftButton" then
            BotInspect:ExecuteDefaultInventoryClick(self.actionSelector or self.item)
        end
    end)
    local inventoryScroll = self.frame and self.frame.inventoryPanel and self.frame.inventoryPanel.scroll
    if inventoryScroll then bindMouseWheel(button, inventoryScroll, 44) end
    self.inventoryButtons[index] = button
    return button
end

function BotInspect:GetInventoryHeader(index, parent)
    local header = self.inventoryHeaders[index]
    if header then header:SetParent(parent); return header end
    header = createText(parent, 10, "LEFT")
    header:SetTextColor(0.68, 0.74, 0.84)
    self.inventoryHeaders[index] = header
    return header
end

function BotInspect:BuildPaperDoll(parent)
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetWidth(MAIN_LEFT_WIDTH)
    panel:SetHeight(454)
    createBackdrop(panel, 0.42)
    self.frame.paperDoll = panel

    local model = CreateFrame("PlayerModel", nil, panel)
    model:SetWidth(206)
    model:SetHeight(306)
    model:SetPoint("TOP", panel, "TOP", 0, -78)
    self.frame.model = model

    local modelFallback = createText(panel, 12, "CENTER")
    modelFallback:SetWidth(190)
    modelFallback:SetPoint("CENTER", model, "CENTER", 0, 0)
    modelFallback:SetTextColor(0.55, 0.58, 0.62)
    modelFallback:SetText("Character preview")
    self.frame.modelFallback = modelFallback

    local slotMap = API:GetEquipmentSlotMap() or {}
    for _, descriptor in ipairs(slotMap) do
        local uiSlot = tonumber(descriptor.uiSlot)
        local pos = uiSlot and PAPERDOLL_POSITIONS[uiSlot]
        if pos then
            local button = CreateFrame("Button", nil, panel)
            button:SetWidth(38); button:SetHeight(38)
            button:SetPoint("TOPLEFT", panel, "TOPLEFT", pos[1], pos[2])
            button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            createBackdrop(button, 0.82)
            button.descriptor = descriptor
            local icon = button:CreateTexture(nil, "ARTWORK")
            icon:SetPoint("TOPLEFT", button, "TOPLEFT", 2, -2)
            icon:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -2, 2)
            icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
            button.icon = icon
            local empty = createText(button, 7, "CENTER")
            empty:SetPoint("CENTER", button, "CENTER", 0, 0)
            empty:SetWidth(34)
            empty:SetTextColor(0.48, 0.50, 0.54)
            empty:SetText(string.sub(SLOT_SHORT[descriptor.slotName] or "Slot", 1, 5))
            button.emptyText = empty
            button:SetScript("OnEnter", function(self) BotInspect:EquipmentButtonEnter(self) end)
            button:SetScript("OnLeave", function() GameTooltip:Hide() end)
            button:SetScript("OnClick", function(self, mouseButton)
                if mouseButton == "RightButton" and (not IsShiftKeyDown or IsShiftKeyDown()) and self.data then
                    BotInspect:OpenItemMenu(self, nil, self.data)
                end
            end)
            self.equipmentButtons[uiSlot] = button
        end
    end
    return panel
end

function BotInspect:BuildInventoryArea(parent)
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetWidth(INVENTORY_WIDTH)
    panel:SetHeight(454)
    createBackdrop(panel, 0.42)
    self.frame.inventoryPanel = panel

    local heading = createText(panel, 13, "LEFT")
    heading:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -8)
    heading:SetText("Inventory")
    panel.heading = heading
    local hint = createText(panel, 9, "RIGHT")
    hint:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -10, -10)
    hint:SetTextColor(0.45, 0.70, 0.95)
    hint:SetText("RMB = Equip   Drag = Move/Swap   Shift+RMB = actions")

    local modeLabel = createText(panel, 9, "LEFT")
    modeLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -31)
    modeLabel:SetText("Default left-click:")
    modeLabel:SetTextColor(0.68, 0.72, 0.78)
    panel.actionButtons = {}
    local actionDefs = { { "NONE", "None", 46 }, { "SELL", "Sell", 46 }, { "GIVE", "Give", 46 }, { "DESTROY", "Destroy", 58 } }
    local actionX = 96
    for _, def in ipairs(actionDefs) do
        local actionId, label, width = def[1], def[2], def[3]
        local b = createButton(panel, label, width, 19)
        b:SetPoint("TOPLEFT", panel, "TOPLEFT", actionX, -27)
        b:SetScript("OnClick", function() BotInspect:SetDefaultInventoryAction(actionId == "NONE" and nil or actionId) end)
        panel.actionButtons[actionId] = b
        actionX = actionX + width + 4
    end
    local modeText = createText(panel, 8, "LEFT")
    modeText:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -50)
    modeText:SetPoint("RIGHT", panel, "RIGHT", -10, 0)
    panel.actionModeText = modeText

    local filters = {
        { FILTER_ALL, "All" }, { FILTER_GEAR, "Gear" }, { FILTER_CONSUMABLES, "Consumables" }, { FILTER_QUEST, "Quest" },
    }
    panel.filterButtons = {}
    local x = 10
    for _, def in ipairs(filters) do
        local w = def[1] == FILTER_CONSUMABLES and 92 or 58
        local b = createButton(panel, def[2], w, 20)
        b:SetPoint("TOPLEFT", panel, "TOPLEFT", x, -66)
        b:SetScript("OnClick", function() BotInspect.inventoryFilter = def[1]; BotInspect:RenderInventory() end)
        panel.filterButtons[def[1]] = b
        x = x + w + 4
    end

    local summary = createText(panel, 9, "LEFT")
    summary:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -91)
    summary:SetPoint("RIGHT", panel, "RIGHT", -10, 0)
    summary:SetTextColor(0.58, 0.62, 0.68)
    panel.summary = summary

    local scroll = CreateFrame("ScrollFrame", "ElvUI_Multibot_BotInspectInventoryScrollFrame", panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -109)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -28, 8)
    panel.scroll = scroll
    local child = CreateFrame("Frame", nil, scroll)
    child:SetWidth(INVENTORY_WIDTH - 44)
    child:SetHeight(380)
    scroll:SetScrollChild(child)
    panel.child = child
    bindMouseWheel(panel, scroll, 44)
    bindMouseWheel(scroll, scroll, 44)
    bindMouseWheel(child, scroll, 44)
    for _, filterButton in pairs(panel.filterButtons or {}) do bindMouseWheel(filterButton, scroll, 44) end
    for _, actionButton in pairs(panel.actionButtons or {}) do bindMouseWheel(actionButton, scroll, 44) end
    local empty = createText(child, 11, "CENTER")
    empty:SetWidth(INVENTORY_WIDTH - 70)
    empty:SetPoint("TOP", child, "TOP", 0, -28)
    empty:SetTextColor(0.60, 0.62, 0.66)
    panel.empty = empty
    return panel
end

local ROSTER_VISIBLE_ROWS = 13
local ROSTER_ROW_HEIGHT = 40

function BotInspect:ScrollRoster(delta)
    local entries = self.rosterEntries or {}
    local maxOffset = math.max(0, #entries - ROSTER_VISIBLE_ROWS)
    local current = tonumber(self.rosterOffset) or 0
    local step = (tonumber(delta) or 0) > 0 and -1 or 1
    if tonumber(delta) == 0 then step = 0 end
    self.rosterOffset = clamp(current + step, 0, maxOffset)
    self:RenderRosterWindow()
end

local function bindRosterWheel(frame)
    if not frame or type(frame.EnableMouseWheel) ~= "function" or type(frame.SetScript) ~= "function" then return end
    if type(frame.EnableMouse) == "function" then frame:EnableMouse(true) end
    frame:EnableMouseWheel(true)
    frame:SetScript("OnMouseWheel", function(_, delta) BotInspect:ScrollRoster(delta) end)
end

function BotInspect:GetRosterRow(index, parent)
    local row = self.rosterRows[index]
    if row then row:SetParent(parent); return row end
    row = CreateFrame("Button", nil, parent)
    row:SetHeight(38)
    createBackdrop(row, 0.45)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    local heading = createText(row, 9, "LEFT")
    heading:SetPoint("LEFT", row, "LEFT", 5, 0)
    heading:SetPoint("RIGHT", row, "RIGHT", -5, 0)
    row.headingText = heading

    local dot = row:CreateTexture(nil, "ARTWORK")
    dot:SetTexture("Interface\\Buttons\\WHITE8X8")
    dot:SetWidth(7); dot:SetHeight(7)
    dot:SetPoint("LEFT", row, "LEFT", 7, 7)
    row.dot = dot
    local name = createText(row, 10, "LEFT")
    name:SetPoint("TOPLEFT", row, "TOPLEFT", 20, -4)
    name:SetWidth(138)
    row.nameText = name
    local info = createText(row, 8, "LEFT")
    info:SetPoint("TOPLEFT", row, "TOPLEFT", 20, -20)
    info:SetWidth(182)
    info:SetTextColor(0.55, 0.57, 0.61)
    row.infoText = info
    local state = createText(row, 8, "CENTER")
    state:SetWidth(44)
    state:SetPoint("RIGHT", row, "RIGHT", -52, 7)
    row.stateText = state
    local lifecycle = createIconButton(row, "Interface\\Icons\\INV_Gizmo_GoblinBoomBox_01", 22)
    lifecycle:SetPoint("RIGHT", row, "RIGHT", -27, 0)
    lifecycle:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    lifecycle:SetScript("OnEnter", function(self)
        local botName = self.botName
        local online = botName and BotInspect:IsBotOnline(botName)
        showSimpleTooltip(self, online and "Go Offline" or "Go Online", "Core managed CONNECT/DISCONNECT lifecycle control.")
    end)
    lifecycle:SetScript("OnLeave", function() GameTooltip:Hide() end)
    lifecycle:SetScript("OnClick", function(self, button)
        if button == "RightButton" and IsShiftKeyDown and IsShiftKeyDown() and self.rosterBot then BotInspect:OpenRosterMenu(self, self.rosterBot); return end
        if self.botName then BotInspect:RequestLifecycle(self.botName) end
    end)
    row.lifecycle = lifecycle
    local summon = createIconButton(row, "Interface\\Icons\\Ability_Hunter_BeastCall", 22)
    summon:SetPoint("RIGHT", row, "RIGHT", -2, 0)
    summon:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    summon:SetScript("OnEnter", function(self) showSimpleTooltip(self, "Summon", "Summon this online Playerbot to your position.") end)
    summon:SetScript("OnLeave", function() GameTooltip:Hide() end)
    summon:SetScript("OnClick", function(self, button)
        if button == "RightButton" and IsShiftKeyDown and IsShiftKeyDown() and self.rosterBot then BotInspect:OpenRosterMenu(self, self.rosterBot); return end
        if self.botName then BotInspect:SummonBot(self.botName) end
    end)
    row.summon = summon
    row:SetScript("OnClick", function(self, mouseButton)
        if self.kind ~= "BOT" then return end
        if mouseButton == "RightButton" and IsShiftKeyDown and IsShiftKeyDown() then BotInspect:OpenRosterMenu(self, self.rosterBot); return end
        if mouseButton == "LeftButton" and self.botName and IsControlKeyDown and IsControlKeyDown() then BotInspect:ToggleActivePresetMember(self.botName); return end
        if mouseButton == "LeftButton" and self.botName then BotInspect:SelectBot(self.botName) end
    end)
    bindRosterWheel(row); bindRosterWheel(lifecycle); bindRosterWheel(summon)
    self.rosterRows[index] = row
    return row
end

function BotInspect:BuildRosterMenu()
    if self.rosterMenu then return self.rosterMenu end
    local menu = CreateFrame("Frame", "ElvUI_Multibot_BotInspectRosterMenu", UIParent, "UIDropDownMenuTemplate")
    self.rosterMenu = menu
    UIDropDownMenu_Initialize(menu, function(_, level)
        level = level or 1
        if level ~= 1 then return end
        local bot = BotInspect.contextRosterBot
        local title = UIDropDownMenu_CreateInfo()
        title.text = bot and ("BotInspect: " .. tostring(bot.name)) or "BotInspect Roster"
        title.isTitle = true; title.notCheckable = true
        UIDropDownMenu_AddButton(title, level)
        if bot then
            local forget = UIDropDownMenu_CreateInfo()
            forget.notCheckable = true
            if bot.managed == true then
                local ref = { name = bot.name, guid = tonumber(bot.guid) }
                local availability = type(API.GetForgetManagedBotAvailability) == "function" and API:GetForgetManagedBotAvailability(ref) or nil
                if availability and availability.enabled == true then
                    forget.text = "Forget from Core"
                    forget.func = function() BotInspect:ConfirmForgetRosterBot(bot) end
                else
                    forget.text = "Forget unavailable: " .. tostring(availability and availability.reason or "MANAGED_BOT_NOT_FOUND")
                    forget.disabled = true
                end
            else
                forget.text = "Forget unavailable: resolving managed identity"
                forget.disabled = true
            end
            UIDropDownMenu_AddButton(forget, level)
        end
    end, "MENU")
    return menu
end

function BotInspect:OpenRosterMenu(anchor, bot)
    if type(IsShiftKeyDown) == "function" and not IsShiftKeyDown() then return end
    self.contextRosterBot = type(bot) == "table" and bot or nil
    local menu = self:BuildRosterMenu()
    if type(ToggleDropDownMenu) == "function" then ToggleDropDownMenu(1, nil, menu, anchor, 0, 0) end
end

function BotInspect:BuildRoster(parent)
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetWidth(ROSTER_WIDTH)
    panel:SetPoint("TOPLEFT", parent, "TOPLEFT", MAIN_WIDTH + HANDLE_WIDTH, 0)
    panel:SetPoint("BOTTOM", parent, "BOTTOM", 0, 0)
    createBackdrop(panel, 0.98)
    panel:EnableMouse(true)
    panel:SetScript("OnMouseUp", function(self, button)
        if button == "RightButton" and IsShiftKeyDown and IsShiftKeyDown() then BotInspect:OpenRosterMenu(self, nil) end
    end)
    self.frame.rosterPanel = panel

    local title = createText(panel, 13, "LEFT")
    title:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -10)
    title:SetText("Bot Roster")
    panel.title = title
    local disconnectAll = createButton(panel, "Disconnect All", 88, 20)
    disconnectAll:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -38, -6)
    disconnectAll:SetScript("OnEnter", function(self) showSimpleTooltip(self, "Disconnect All", "Disconnect every currently ONLINE managed bot through Core. Requests are dispatched two at a time.") end)
    disconnectAll:SetScript("OnLeave", function() GameTooltip:Hide() end)
    disconnectAll:SetScript("OnClick", function() BotInspect:DisconnectAll() end)
    panel.disconnectAll = disconnectAll

    local connectAll = createButton(panel, "Connect All", 82, 20)
    connectAll:SetPoint("RIGHT", disconnectAll, "LEFT", -4, 0)
    connectAll:SetScript("OnEnter", function(self) showSimpleTooltip(self, "Connect All", "Connect every currently OFFLINE managed bot through Core. Requests are dispatched two at a time.") end)
    connectAll:SetScript("OnLeave", function() GameTooltip:Hide() end)
    connectAll:SetScript("OnClick", function() BotInspect:ConnectAll() end)
    panel.connectAll = connectAll

    local search = CreateFrame("EditBox", "ElvUI_Multibot_BotInspectRosterSearchBox", panel, "InputBoxTemplate")
    search:SetWidth(224); search:SetHeight(20)
    search:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -31)
    search:SetAutoFocus(false); search:SetMaxLetters(32)
    search:SetScript("OnTextChanged", function() BotInspect.rosterOffset = 0; BotInspect:RefreshRoster() end)
    search:SetScript("OnEnterPressed", function(self)
        local text = trim(self:GetText())
        if text ~= "" then BotInspect:DiscoverBot(text, true) end
        self:ClearFocus()
    end)
    search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    self.frame.rosterSearch = search

    local discover = createButton(panel, "+", 28, 20)
    discover:SetPoint("LEFT", search, "RIGHT", 5, 0)
    discover:SetScript("OnEnter", function(self) showSimpleTooltip(self, "Discover bot", "Resolve an exact linked-account character name through Core.") end)
    discover:SetScript("OnLeave", function() GameTooltip:Hide() end)
    discover:SetScript("OnClick", function() local text = trim(search:GetText()); if text ~= "" then BotInspect:DiscoverBot(text, true) end end)

    local presetSelect = createButton(panel, "No preset", 100, 20)
    presetSelect:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -57)
    presetSelect:SetScript("OnEnter", function(self) showSimpleTooltip(self, "Summon preset", "Choose a saved bot group. Ctrl+click roster rows to add or remove bots from the active preset.") end)
    presetSelect:SetScript("OnLeave", function() GameTooltip:Hide() end)
    presetSelect:SetScript("OnClick", function(self) if type(ToggleDropDownMenu) == "function" then ToggleDropDownMenu(1, nil, BotInspect:BuildPresetSelectMenu(), self, 0, 0) end end)
    panel.presetSelect = presetSelect

    local presetSave = createButton(panel, "Save Group", 62, 20)
    presetSave:SetPoint("LEFT", presetSelect, "RIGHT", 4, 0)
    presetSave:SetScript("OnEnter", function(self) showSimpleTooltip(self, "Save current group", "Save the Playerbots currently in your party/raid as a named preset. Reusing a preset name updates its members. An empty group creates an empty preset that you can fill with Ctrl+click.") end)
    presetSave:SetScript("OnLeave", function() GameTooltip:Hide() end)
    presetSave:SetScript("OnClick", function() BotInspect:ShowSaveGroupPresetPopup() end)
    panel.presetSave = presetSave

    local presetSummon = createButton(panel, "Summon", 58, 20)
    presetSummon:SetPoint("LEFT", presetSave, "RIGHT", 4, 0)
    presetSummon:SetScript("OnEnter", function(self) showSimpleTooltip(self, "Summon preset", "Summon every member of the active preset. Offline managed bots are connected through Core first, then summoned as they come online.") end)
    presetSummon:SetScript("OnLeave", function() GameTooltip:Hide() end)
    presetSummon:SetScript("OnClick", function() local name = BotInspect:GetActiveGroupPreset(); if name then BotInspect:SummonGroupPreset(name) end end)
    panel.presetSummon = presetSummon

    local presetActions = createButton(panel, "...", 24, 20)
    presetActions:SetPoint("LEFT", presetSummon, "RIGHT", 4, 0)
    presetActions:SetScript("OnEnter", function(self) showSimpleTooltip(self, "Preset actions", "Rename, replace from the current party/raid, clear members, or delete the active preset.") end)
    presetActions:SetScript("OnLeave", function() GameTooltip:Hide() end)
    presetActions:SetScript("OnClick", function(self) if type(ToggleDropDownMenu) == "function" then ToggleDropDownMenu(1, nil, BotInspect:BuildPresetActionsMenu(), self, 0, 0) end end)
    panel.presetActions = presetActions

    local list = CreateFrame("Frame", nil, panel)
    list:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -86)
    list:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -22, 8)
    panel.list = list

    local slider = CreateFrame("Slider", nil, panel)
    slider:SetOrientation("VERTICAL")
    slider:SetWidth(12)
    slider:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -5, -91)
    slider:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -5, 12)
    slider:SetMinMaxValues(0, 0); slider:SetValueStep(1); slider:SetValue(0)
    slider:SetThumbTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
    local thumb = slider:GetThumbTexture()
    if thumb then thumb:SetWidth(18); thumb:SetHeight(24) end
    slider:SetScript("OnValueChanged", function(self, value)
        if panel.updatingSlider then return end
        local maximum = tonumber(panel.rosterMaxOffset) or 0
        BotInspect.rosterOffset = clamp(maximum - math.floor((tonumber(value) or 0) + 0.5), 0, maximum)
        BotInspect:RenderRosterWindow()
    end)
    panel.slider = slider

    for i = 1, ROSTER_VISIBLE_ROWS do
        local row = self:GetRosterRow(i, list)
        row:SetPoint("TOPLEFT", list, "TOPLEFT", 0, -((i - 1) * ROSTER_ROW_HEIGHT))
        row:SetWidth(244)
    end

    bindRosterWheel(panel); bindRosterWheel(list); bindRosterWheel(search); bindRosterWheel(discover); bindRosterWheel(connectAll); bindRosterWheel(disconnectAll); bindRosterWheel(presetSelect); bindRosterWheel(presetSave); bindRosterWheel(presetSummon); bindRosterWheel(presetActions); bindRosterWheel(slider)
    self:RefreshPresetControls()
    return panel
end

function BotInspect:RenderRosterWindow()
    if not self.frame or not self.frame.rosterPanel then return end
    local panel = self.frame.rosterPanel
    local entries = self.rosterEntries or {}
    local maxOffset = math.max(0, #entries - ROSTER_VISIBLE_ROWS)
    self.rosterOffset = clamp(tonumber(self.rosterOffset) or 0, 0, maxOffset)

    panel.rosterMaxOffset = maxOffset
    if panel.slider then
        panel.updatingSlider = true
        panel.slider:SetMinMaxValues(0, maxOffset)
        panel.slider:SetValue(maxOffset - self.rosterOffset)
        panel.updatingSlider = false
        if maxOffset > 0 then panel.slider:Show() else panel.slider:Hide() end
    end

    for i = 1, ROSTER_VISIBLE_ROWS do
        local row = self.rosterRows[i]
        local entry = entries[self.rosterOffset + i]
        if row and entry then
            row:Show()
            if entry.kind == "HEADING" then
                row.kind = "HEADING"; row.botName = nil; row.rosterBot = nil
                row:SetBackdropColor(0.035, 0.035, 0.045, 0.25)
                row:SetBackdropBorderColor(0.18, 0.18, 0.22, 1)
                row.headingText:SetText(entry.text or "")
                row.headingText:SetTextColor(entry.online and 0.35 or 0.70, entry.online and 0.90 or 0.70, entry.online and 0.50 or 0.72)
                row.headingText:Show(); row.dot:Hide(); row.nameText:Hide(); row.infoText:Hide(); row.stateText:Hide(); row.lifecycle:Hide(); row.summon:Hide()
            else
                local bot = entry.bot
                row.kind = "BOT"; row.rosterBot = bot; row.botName = bot.name
                row.headingText:Hide(); row.dot:Show(); row.nameText:Show(); row.infoText:Show(); row.stateText:Show(); row.lifecycle:Show(); row.summon:Show()
                row.lifecycle.botName = bot.name; row.lifecycle.rosterBot = bot
                row.summon.botName = bot.name; row.summon.rosterBot = bot
                local selected = self.selectedBot == bot.name
                row:SetBackdropColor(selected and 0.07 or 0.045, selected and 0.18 or 0.045, selected and 0.27 or 0.055, selected and 0.95 or 0.45)
                local _, activePreset = self:GetActiveGroupPreset()
                local presetMember = activePreset and self:IsBotInGroupPreset(bot.name, activePreset) or false
                if presetMember then row:SetBackdropBorderColor(0.25, 0.85, 0.45, 1) else row:SetBackdropBorderColor(0.18, 0.18, 0.22, 1) end
                local r, g, b = classColor(bot.class)
                row.nameText:SetTextColor(r, g, b); row.nameText:SetText(bot.name)
                local spec, role, score = self:GetBotDisplayProfile(bot.name)
                local profile = tostring(spec) .. " · " .. tostring(role) .. " · GS " .. (score and tostring(math.floor(score)) or "--")
                if bot.online then
                    row.dot:SetVertexColor(0.30, 0.95, 0.45)
                    row.stateText:SetTextColor(0.30, 0.95, 0.45); row.stateText:SetText("LIVE")
                    row.infoText:SetText(bot.managed == true and profile or ("Learning identity... · " .. profile))
                else
                    row.dot:SetVertexColor(0.45, 0.45, 0.48)
                    row.stateText:SetTextColor(0.70, 0.70, 0.72); row.stateText:SetText("OFFLINE")
                    local stamp = self:GetLatestHistoricalObservedAt(bot.name)
                    row.infoText:SetText(profile .. (stamp and (" · " .. ageText(stamp)) or ""))
                end
                local pending = self.lifecyclePending[bot.name] == true
                local action = bot.online and "DISCONNECT" or "CONNECT"
                local avail = bot.managed == true and type(API.GetManagedBotLifecycleAvailability) == "function" and API:GetManagedBotLifecycleAvailability(bot.name, action) or nil
                setButtonEnabled(row.lifecycle, bot.managed == true and not pending and not self.presetSummonRunning and avail and avail.enabled == true)
                setButtonEnabled(row.summon, bot.online and not pending)
            end
        elseif row then
            row:Hide(); row.kind = nil; row.botName = nil; row.rosterBot = nil
        end
    end
end

function BotInspect:RefreshRoster()
    if not self.frame or not self.frame.rosterPanel then return end
    self.lastKnownSummaryCache = {}
    local panel = self.frame.rosterPanel
    local query = lower(self.frame.rosterSearch and trim(self.frame.rosterSearch:GetText()) or "")
    local bots = self:GetSelectableBots()
    if panel.title then panel.title:SetText("Bot Roster (" .. tostring(#bots) .. ")") end
    self:QueueAutoResolveUnmanagedLiveBots(bots)
    self:QueueHistoryPrimeBots(bots)
    local online, offline = {}, {}
    for _, bot in ipairs(bots) do
        if query == "" or string.find(lower(bot.name), query, 1, true) then
            if bot.online then online[#online + 1] = bot else offline[#offline + 1] = bot end
        end
    end
    self:RefreshPresetControls()
    if panel.connectAll or panel.disconnectAll then
        local anyConnectable, anyDisconnectable = false, false
        if not self.bulkLifecycleRunning and not self.presetSummonRunning then
            for _, bot in ipairs(bots) do
                if bot.managed == true and not self.lifecyclePending[bot.name] then
                    if not bot.online and not anyConnectable then
                        local availability = type(API.GetManagedBotLifecycleAvailability) == "function" and API:GetManagedBotLifecycleAvailability(bot.name, "CONNECT") or nil
                        if availability and availability.enabled == true then anyConnectable = true end
                    elseif bot.online and not anyDisconnectable then
                        local availability = type(API.GetManagedBotLifecycleAvailability) == "function" and API:GetManagedBotLifecycleAvailability(bot.name, "DISCONNECT") or nil
                        if availability and availability.enabled == true then anyDisconnectable = true end
                    end
                end
                if anyConnectable and anyDisconnectable then break end
            end
        end
        if panel.connectAll then setButtonEnabled(panel.connectAll, anyConnectable) end
        if panel.disconnectAll then setButtonEnabled(panel.disconnectAll, anyDisconnectable) end
    end

    local entries = {}
    entries[#entries + 1] = { kind = "HEADING", text = "ONLINE (" .. tostring(#online) .. ")", online = true }
    for _, bot in ipairs(online) do entries[#entries + 1] = { kind = "BOT", bot = bot } end
    entries[#entries + 1] = { kind = "HEADING", text = "OFFLINE (" .. tostring(#offline) .. ")", online = false }
    for _, bot in ipairs(offline) do entries[#entries + 1] = { kind = "BOT", bot = bot } end
    self.rosterEntries = entries
    local maxOffset = math.max(0, #entries - ROSTER_VISIBLE_ROWS)
    self.rosterOffset = clamp(tonumber(self.rosterOffset) or 0, 0, maxOffset)
    self:RenderRosterWindow()
end

function BotInspect:RenderHeader()
    if not self.frame then return end
    local name = self.selectedBot or "Select a bot"
    self.frame.botName:SetText(name)
    if not self.selectedBot then
        self.frame.botDesc:SetText("Choose a bot from the roster")
        self.frame.modeText:SetText("NO BOT")
        self.frame.modeText:SetTextColor(0.55, 0.58, 0.62)
        return
    end
    local live = self:IsSelectedBotOnline()
    local detail = select(1, self:GetDisplayDomain("BOT.DETAIL")) or {}
    local managed = self:GetSelectedManagedRecord() or {}
    local bot = API:GetBot(self.selectedBot) or {}
    local level = tonumber(detail.level) or tonumber(bot.level) or tonumber(managed.level)
    local race = detail.race or managed.race
    local class = detail.className or detail.class or bot.className or bot.class or managed.className or managed.class
    local desc = {}
    if level then desc[#desc + 1] = "Level " .. tostring(level) end
    if race and trim(race) ~= "" then desc[#desc + 1] = tostring(race) end
    if class and trim(class) ~= "" then desc[#desc + 1] = tostring(class) end
    self.frame.botDesc:SetText(#desc > 0 and table.concat(desc, " ") or "Managed Playerbot")
    if live then
        self.frame.modeText:SetText("LIVE")
        self.frame.modeText:SetTextColor(0.30, 0.95, 0.45)
    else
        self.frame.modeText:SetText("OFFLINE / HISTORY")
        self.frame.modeText:SetTextColor(0.95, 0.72, 0.30)
    end
    if self.frame.refresh then setButtonEnabled(self.frame.refresh, live) end
end

function BotInspect:RenderModel()
    if not self.frame or not self.frame.model then return end
    local model = self.frame.model
    local fallback = self.frame.modelFallback
    if not self.selectedBot or not self:IsSelectedBotOnline() then
        model:Hide(); fallback:Show()
        fallback:SetText(self.selectedBot and "Offline historical view\nNo live character model" or "Character preview")
        return
    end
    local unit = findUnitForName(self.selectedBot)
    if not unit then
        model:Hide(); fallback:Show(); fallback:SetText("Live bot\nCharacter model unavailable")
        return
    end
    local ok = type(model.SetUnit) == "function" and pcall(model.SetUnit, model, unit)
    if ok then
        if type(model.SetPortraitZoom) == "function" then pcall(model.SetPortraitZoom, model, 0.05) end
        model:Show(); fallback:Hide()
    else
        model:Hide(); fallback:Show(); fallback:SetText("Character model unavailable")
    end
end

function BotInspect:RenderEquipment()
    for _, button in pairs(self.equipmentButtons) do
        button.data = nil; button.historical = false; button.icon:SetTexture(nil); button.emptyText:Show(); setQualityBorder(button, nil)
    end
    if not self.selectedBot then return end
    local live = self:IsSelectedBotOnline()
    local equipment, meta, historical = nil, nil, false
    if live then
        equipment, meta = API:GetEquipmentView(self.selectedBot)
        if not equipment then
            equipment, meta = API:GetLastKnown("BOT.EQUIPMENT", self.selectedBot)
            historical = equipment ~= nil
        end
    else
        equipment, meta = API:GetLastKnown("BOT.EQUIPMENT", self.selectedBot)
        historical = equipment ~= nil
    end
    if not equipment then return end
    for _, slot in ipairs(equipment.slots or {}) do
        local button = self.equipmentButtons[tonumber(slot.uiSlot)]
        if button then
            button.data = slot; button.historical = historical
            button.icon:SetTexture(slot.texture)
            if slot.itemLink or slot.texture then button.emptyText:Hide() end
            setQualityBorder(button, slot.quality)
        end
    end
end

function BotInspect:RenderInventory()
    local panel = self.frame and self.frame.inventoryPanel
    if not panel then return end
    self:RenderInventoryActionStrip()
    for _, button in ipairs(self.inventoryButtons) do
        button:Hide(); button.inventoryBag = nil; button.inventorySlot = nil; button.item = nil; button.actionSelector = nil
    end
    for _, header in ipairs(self.inventoryHeaders) do header:Hide() end
    for id, button in pairs(panel.filterButtons or {}) do
        if button.label then button.label:SetTextColor(id == self.inventoryFilter and 0.25 or 0.86, id == self.inventoryFilter and 0.75 or 0.86, id == self.inventoryFilter and 1.0 or 0.88) end
    end
    if not self.selectedBot then panel.summary:SetText("No bot selected"); panel.empty:SetText("Select a bot from the roster."); panel.empty:Show(); return end
    local live = self:IsSelectedBotOnline()
    local exact, exactMeta, flat, historical = nil, nil, nil, false
    if live then
        exact, exactMeta = API:GetInventoryExactView(self.selectedBot)
        flat = select(1, API:GetInventoryView(self.selectedBot))
        if not exact then
            exact, exactMeta = API:GetLastKnown("BOT.INVENTORY_EXACT", self.selectedBot)
            flat = select(1, API:GetLastKnown("BOT.INVENTORY", self.selectedBot))
            historical = exact ~= nil
        end
    else
        exact, exactMeta = API:GetLastKnown("BOT.INVENTORY_EXACT", self.selectedBot)
        flat = select(1, API:GetLastKnown("BOT.INVENTORY", self.selectedBot))
        historical = exact ~= nil
    end
    if not exact then
        panel.summary:SetText(live and "Waiting for physical inventory..." or "Offline - no saved physical inventory")
        panel.empty:SetText(live and "Waiting for BOT.INVENTORY_EXACT (automatic retry active)..." or "No historical inventory retained yet.")
        panel.empty:Show(); return
    end
    panel.empty:Hide()
    local summary = exact.summary or {}
    if historical then
        panel.summary:SetText(string.format("Last observed %d/%d - %s%s", tonumber(summary.bagUsed) or 0, tonumber(summary.bagTotal) or 0, observedAtText(exactMeta), live and " · refreshing live" or ""))
    else
        panel.summary:SetText(string.format("%d/%d used - %d free", tonumber(summary.bagUsed) or 0, tonumber(summary.bagTotal) or 0, tonumber(summary.bagFree) or 0))
    end
    local flatById = buildFlatItemLookup(flat)
    local bags = {}
    for _, bag in ipairs(exact.bags or {}) do bags[#bags + 1] = bag end
    table.sort(bags, function(a, b)
        local ak = a.kind == "BACKPACK" and 0 or (a.kind == "BAG" and 1 or 2)
        local bk = b.kind == "BACKPACK" and 0 or (b.kind == "BAG" and 1 or 2)
        if ak ~= bk then return ak < bk end
        return (tonumber(a.bag) or 0) < (tonumber(b.bag) or 0)
    end)
    local db = self:GetSettings()
    local size = tonumber(db.itemSize) or 32
    local gap = 3
    local columns = tonumber(db.inventoryColumns) or 10
    local maxColumns = math.max(8, math.floor((INVENTORY_WIDTH - 52) / (size + gap)))
    columns = math.min(columns, maxColumns)
    local y = -2
    local buttonIndex, headerIndex = 0, 0
    local childWidth = math.max(330, columns * (size + gap) + 4)
    panel.child:SetWidth(childWidth)
    for _, descriptor in ipairs(bags) do
        headerIndex = headerIndex + 1
        local header = self:GetInventoryHeader(headerIndex, panel.child)
        header:ClearAllPoints(); header:SetPoint("TOPLEFT", panel.child, "TOPLEFT", 2, y); header:SetWidth(childWidth - 4); header:Show()
        local bag = tonumber(descriptor.bag) or 0
        local slotStart = tonumber(descriptor.slotStart) or 0
        local slotCount = tonumber(descriptor.slotCount) or 0
        local used = 0
        for slot = slotStart, slotStart + slotCount - 1 do if exact.itemsByPosition and exact.itemsByPosition[tostring(bag) .. ":" .. tostring(slot)] then used = used + 1 end end
        header:SetText(string.format("%s  %d/%d", bagLabel(descriptor), used, slotCount))
        y = y - 16
        for offset = 0, slotCount - 1 do
            buttonIndex = buttonIndex + 1
            local button = self:GetInventoryButton(buttonIndex, panel.child)
            local row = math.floor(offset / columns)
            local column = offset % columns
            local slot = slotStart + offset
            button:ClearAllPoints(); button:SetWidth(size); button:SetHeight(size)
            button:SetPoint("TOPLEFT", panel.child, "TOPLEFT", 2 + column * (size + gap), y - row * (size + gap)); button:Show()
            button.inventoryBag = bag; button.inventorySlot = slot
            local item = exact.itemsByPosition and exact.itemsByPosition[tostring(bag) .. ":" .. tostring(slot)] or nil
            button.item = item; button.historical = historical; button.itemLink = nil; button.itemName = nil; button.actionSelector = nil
            button.icon:SetTexture(nil); button.countText:SetText(""); button.soulboundText:Hide(); button:SetAlpha(1); setQualityBorder(button, nil)
            if item then
                local flatItem = flatById[tonumber(item.itemId)]
                local name, link, quality, _, _, _, _, _, _, texture
                if type(GetItemInfo) == "function" then name, link, quality, _, _, _, _, _, _, texture = GetItemInfo(tonumber(item.itemId) or 0) end
                if flatItem then
                    name = flatItem.name or name; link = flatItem.link or flatItem.clientLink or flatItem.serverLink or link
                    quality = flatItem.quality ~= nil and flatItem.quality or quality; texture = flatItem.icon or texture
                end
                if not texture and type(GetItemIcon) == "function" then texture = GetItemIcon(tonumber(item.itemId) or 0) end
                button.itemLink = link; button.itemName = name
                button.actionSelector = { itemId = item.itemId, bag = item.bag, slot = item.slot, count = item.count, link = link, serverLink = item.serverLink, name = name }
                button.icon:SetTexture(texture or "Interface\\Icons\\INV_Misc_QuestionMark")
                if tonumber(item.count) and tonumber(item.count) > 1 then button.countText:SetText(tostring(item.count)) end
                if item.soulbound then button.soulboundText:Show() end
                setQualityBorder(button, quality)
                if not matchesInventoryFilter(self.inventoryFilter, flatItem) then button:SetAlpha(0.16) end
            else
                if self.inventoryFilter ~= FILTER_ALL then button:SetAlpha(0.10) end
            end
        end
        local rows = math.max(1, math.ceil(slotCount / columns))
        y = y - rows * (size + gap) - 8
    end
    if #bags == 0 then panel.empty:SetText("Core returned no physical bag descriptors."); panel.empty:Show(); y = -70 end
    panel.child:SetHeight(math.max(380, -y + 8))
    if panel.scroll and type(panel.scroll.UpdateScrollChildRect) == "function" then pcall(panel.scroll.UpdateScrollChildRect, panel.scroll) end
    scrollFrameByWheel(panel.scroll, 0, 44)
end

function BotInspect:RenderSummaryBar()
    if not self.frame or not self.frame.summaryBar then return end
    local bar = self.frame.summaryBar
    if not self.selectedBot then
        bar.gold:SetText("Gold: --"); bar.durability:SetText("Durability: --"); bar.bags:SetText("Bags: --"); bar.spec:SetText("Spec: --"); bar.score:SetText("Gear Score: --")
        return
    end
    local stats = select(1, self:GetDisplayDomain("BOT.STATS")) or {}
    local copper = (tonumber(stats.gold) or 0) * 10000 + (tonumber(stats.silver) or 0) * 100 + (tonumber(stats.copper) or 0)
    bar.gold:SetText("Gold: " .. (next(stats) and moneyText(copper) or "--"))
    bar.durability:SetText("Durability: " .. percentText(stats.durabilityPct))
    local used, total = tonumber(stats.bagUsed), tonumber(stats.bagTotal)
    bar.bags:SetText("Bags: " .. ((used and total and total > 0) and (tostring(used) .. "/" .. tostring(total)) or "--"))
    local spec, role, score = self:GetBotDisplayProfile(self.selectedBot)
    bar.spec:SetText("Spec: " .. tostring(spec) .. (role ~= "--" and (" / " .. tostring(role)) or ""))
    bar.score:SetText("Gear Score: " .. (score and tostring(math.floor(score)) or "--"))
end

function BotInspect:RenderAll()
    if not self.frame or not self.uiReady then return end
    self:RenderHeader()
    if type(self.ApplyActiveView) == "function" then self:ApplyActiveView() end
    if self.activeView == "QUESTS" and type(self.RenderQuests) == "function" then
        self:RenderQuests()
    elseif self.activeView == "SPELLBOOK" and type(self.RenderSpellbook) == "function" then
        self:RenderSpellbook()
    else
        self:RenderModel()
        self:RenderEquipment()
        self:RenderInventory()
    end
    self:RenderSummaryBar()
    self:RefreshRoster()
end

function BotInspect:BuildSummaryBar(parent)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetHeight(30)
    bar:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 8, 28)
    bar:SetPoint("RIGHT", parent, "LEFT", MAIN_WIDTH - 8, 0)
    createBackdrop(bar, 0.90)
    self.frame.summaryBar = bar
    local defs = {
        { "gold", "Gold: --", 10, 120 }, { "durability", "Durability: --", 132, 120 }, { "bags", "Bags: --", 254, 90 },
        { "spec", "Spec: --", 348, 230 }, { "score", "Gear Score: --", 584, 180 },
    }
    for _, d in ipairs(defs) do
        local fs = createText(bar, 10, "LEFT")
        fs:SetPoint("LEFT", bar, "LEFT", d[3], 0); fs:SetWidth(d[4]); fs:SetText(d[2]); bar[d[1]] = fs
    end
    return bar
end

function BotInspect:CreateUI()
    if self.frame and self.uiReady then return self.frame end
    if self.frame and not self.uiReady then pcall(self.frame.Hide, self.frame); self.frame = nil end
    self.uiReady = false
    self.equipmentButtons, self.inventoryButtons, self.inventoryHeaders, self.rosterRows = {}, {}, {}, {}

    local frame = CreateFrame("Frame", "ElvUI_Multibot_BotInspectFrame", UIParent)
    frame:SetHeight(FRAME_HEIGHT)
    frame:SetFrameStrata("DIALOG")
    frame:SetClampedToScreen(true); frame:SetMovable(true); frame:EnableMouse(true); frame:RegisterForDrag("LeftButton")
    createBackdrop(frame, 0.985); frame:Hide(); self.frame = frame
    UISpecialFrames = UISpecialFrames or {}
    local specialFound = false
    for _, specialName in ipairs(UISpecialFrames) do if specialName == "ElvUI_Multibot_BotInspectFrame" then specialFound = true; break end end
    if not specialFound then table.insert(UISpecialFrames, "ElvUI_Multibot_BotInspectFrame") end
    frame:SetScript("OnDragStart", function(self) if not InCombatLockdown or not InCombatLockdown() then self:StartMoving() end end)
    frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); BotInspect:SavePosition() end)
    frame:SetScript("OnShow", function() if type(BotInspect.ApplyActiveView) == "function" then BotInspect:ApplyActiveView() end; BotInspect:UpdateInterests(); BotInspect:RenderAll() end)
    frame:SetScript("OnHide", function() BotInspect:ReleaseAllInterests(); BotInspect:CancelSelectedReliabilityJobs(); if type(CloseDropDownMenus) == "function" then CloseDropDownMenus() end end)

    local title = createText(frame, 12, "LEFT")
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -9); title:SetText("BotInspect")
    local ver = createText(frame, 8, "LEFT")
    ver:SetPoint("LEFT", title, "RIGHT", 6, 0); ver:SetTextColor(0.48, 0.50, 0.54); ver:SetText(VERSION)
    local close = CreateFrame("Button", "ElvUI_Multibot_BotInspectCloseButton", frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0); close:SetScript("OnClick", function() frame:Hide() end)

    local botName = createText(frame, 14, "CENTER")
    botName:SetWidth(330); botName:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -28); botName:SetText("Select a bot")
    frame.botName = botName
    local botDesc = createText(frame, 9, "CENTER")
    botDesc:SetWidth(330); botDesc:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -47); botDesc:SetTextColor(0.78, 0.72, 0.25); botDesc:SetText("Choose a bot from the roster")
    frame.botDesc = botDesc
    local mode = createText(frame, 9, "RIGHT")
    mode:SetWidth(145); mode:SetPoint("TOPRIGHT", frame, "TOPLEFT", MAIN_WIDTH - 20, -35); mode:SetText("NO BOT")
    frame.modeText = mode
    local refresh = createButton(frame, "Refresh", 68, 20)
    refresh:SetPoint("TOPRIGHT", frame, "TOPLEFT", MAIN_WIDTH - 12, -52); refresh:SetScript("OnClick", function() BotInspect:RefreshAll() end)
    frame.refresh = refresh

    if type(self.BuildViewTabs) == "function" then self:BuildViewTabs(frame) end

    local mainBody = CreateFrame("Frame", nil, frame)
    mainBody:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -96)
    mainBody:SetWidth(MAIN_WIDTH - 16); mainBody:SetHeight(470)
    frame.mainBody = mainBody

    local gearView = CreateFrame("Frame", nil, mainBody)
    gearView:SetPoint("TOPLEFT", mainBody, "TOPLEFT", 0, 0)
    gearView:SetPoint("BOTTOMRIGHT", mainBody, "BOTTOMRIGHT", 0, 0)
    frame.gearView = gearView
    local paper = self:BuildPaperDoll(gearView)
    paper:SetPoint("TOPLEFT", gearView, "TOPLEFT", 0, 0)
    local inv = self:BuildInventoryArea(gearView)
    inv:SetPoint("TOPLEFT", paper, "TOPRIGHT", 8, 0)
    if type(self.BuildSpellbookArea) == "function" then self:BuildSpellbookArea(mainBody) end
    if type(self.BuildQuestsArea) == "function" then self:BuildQuestsArea(mainBody) end
    if type(self.ApplyActiveView) == "function" then self:ApplyActiveView() end
    self:BuildSummaryBar(frame)

    local handle = createButton(frame, "<", HANDLE_WIDTH, 48)
    handle:SetPoint("TOPLEFT", frame, "TOPLEFT", MAIN_WIDTH, -255)
    handle:SetScript("OnClick", function()
        local db = BotInspect:GetSettings(); db.rosterExpanded = not (db.rosterExpanded ~= false); BotInspect:ApplyRosterExpanded()
    end)
    frame.rosterHandle = handle
    self:BuildRoster(frame)

    local status = createText(frame, 9, "LEFT")
    status:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 10, 9); status:SetWidth(MAIN_WIDTH - 20); status:SetTextColor(0.62, 0.64, 0.68); status:SetText("Ready")
    frame.status = status

    self:ApplySettings()
    self.uiReady = true
    self:RenderAll()
    return frame
end

function BotInspect:Open(botRef)
    self:CreateUI()
    local wasShown = self.frame and self.frame:IsShown()
    local managed = botRef and API:GetManagedBot(botRef) or nil
    local target = botRef and API:ResolveBot(botRef) or nil
    if managed or (target and target.online == true) then self:SelectBot((managed and managed.name) or target.name)
    elseif not self.selectedBot then
        local default = self:ChooseDefaultBot(); if default then self:SelectBot(default) end
    end
    self.frame:Show(); self:UpdateInterests(); self:RenderAll(); self:ScheduleSelectedEnsure(SELECTED_ENSURE_START_DELAY, false)
    if not wasShown and self.activeView == "SPELLBOOK" and self.selectedBot and self:IsSelectedBotOnline() and type(self.RequestSpellIgnoredList) == "function" then
        self:RequestSpellIgnoredList(self.selectedBot)
    elseif not wasShown and self.activeView == "QUESTS" and self.selectedBot and type(self.RefreshSelectedQuests) == "function" then
        self:RefreshSelectedQuests(true)
    end
end

function BotInspect:Close() if type(self.CancelInventoryDrag) == "function" then self:CancelInventoryDrag(true) end; if self.frame then self.frame:Hide() end; self:CancelSelectedReliabilityJobs() end
function BotInspect:Toggle(botRef) self:CreateUI(); if self.frame:IsShown() then self:Close() else self:Open(botRef) end end

function BotInspect:RefreshBotList()
    local previousSelected = self.selectedBot
    if self.selectedBot and not self:IsSelectableBot(self.selectedBot) then self:ReleaseAllInterests(); self.selectedBot = nil end
    if not self.selectedBot then local default = self:ChooseDefaultBot(); if default then self.selectedBot = default end end
    if self.frame and self.frame:IsShown() then
        self:UpdateInterests(); self:RenderAll()
        if self.activeView == "SPELLBOOK" and self.selectedBot and normalizeName(previousSelected) ~= normalizeName(self.selectedBot) and self:IsSelectedBotOnline() and type(self.RequestSpellIgnoredList) == "function" then
            self:RequestSpellIgnoredList(self.selectedBot)
        elseif self.activeView == "QUESTS" and self.selectedBot and normalizeName(previousSelected) ~= normalizeName(self.selectedBot) and type(self.RefreshSelectedQuests) == "function" then
            self:RefreshSelectedQuests(true)
        end
    else self:RefreshRoster() end
end

function BotInspect:OnCoreEvent(event, ...)
    if event == "MB_DATA_CHANGED" or event == "MB_DATA_UPDATED" or event == "MB_DATA_INVALIDATED" or event == "MB_DATA_ERROR" then
        local domainId, targetKey, payload = ...
        if self:IsSelectedTarget(targetKey) and self.frame and self.frame:IsShown() then
            if RELIABLE_DOMAIN[domainId] then
                local retryKey = self:SelectedRetryKey(domainId)
                if event == "MB_DATA_UPDATED" or event == "MB_DATA_CHANGED" then
                    self.selectedRetryAttempts[retryKey] = nil
                    self:CancelLocal("selected-retry-" .. tostring(domainId))
                elseif event == "MB_DATA_INVALIDATED" or event == "MB_DATA_ERROR" then
                    self:ScheduleSelectedDomainRetry(domainId, payload)
                end
            end
            self:ScheduleFullRefresh(UI_EVENT_COALESCE_DELAY)
        elseif domainId == "BOT.DETAIL" and self.frame then
            self:ScheduleRosterRefresh(UI_EVENT_COALESCE_DELAY)
        end
    elseif event == "MB_BOT_PRESENCE_CHANGED" then
        local bot, online = ...
        local name = type(bot) == "table" and bot.name or nil
        if name and online == true then
            self:ResetHistoryPrimeBot(name)
            if self.selectedBot and normalizeName(self.selectedBot) == normalizeName(name) then
                self:CancelSelectedReliabilityJobs()
                self:ScheduleSelectedEnsure(0.75, false)
            end
        end
        self:ScheduleFullRefresh(UI_EVENT_COALESCE_DELAY)
    elseif event == "MB_BOT_REGISTRY_READY" or event == "MB_BOT_DISCOVERED" or event == "MB_BOT_LIFECYCLE_UPDATED" or event == "MB_MANAGED_ROSTER_UPDATED" or event == "MB_MANAGED_BOT_FORGOTTEN" then
        self:ScheduleFullRefresh(UI_EVENT_COALESCE_DELAY)
        if self.selectedBot and self:IsSelectedBotOnline() and self.frame and self.frame:IsShown() then self:ScheduleSelectedEnsure(0.60, false) end
    elseif event == "MB_SESSION_CHANGED" then
        self:ReleaseAllInterests(); self.lifecyclePending = {}; self:ResetAutoResolveState(); self:ResetHistoryPrimeState(); self:CancelSelectedReliabilityJobs()
        self.bulkLifecycleRunning = false; self.bulkLifecycleAction = nil; self.bulkLifecycleState = nil
        self.presetSummonRunning = false; self.presetSummonState = nil
        self.inventoryMovePending = false
        if type(self.CancelInventoryDrag) == "function" then self:CancelInventoryDrag(true) end
        self.spellIgnoredState = {}
        self.spellIgnoredPending = {}
        self.questRefreshState = nil
        self.scheduledJobs = {}
        self.backgroundResumeAt = 0
        if self.frame and self.frame:IsShown() then
            self:SetStatus("Core session changed; recalculating state...")
            self:ScheduleFullRefresh(UI_EVENT_COALESCE_DELAY)
            self:ScheduleSelectedEnsure(1.0, false)
        end
    end
end

function BotInspect:RegisterCoreIntegration()
    API:RegisterModule(MODULE, { version = VERSION, description = "Integrated gear, inventory, spellbook, quest log and managed-roster frontend.", minimumCore = MIN_CORE })
    local events = {
        "MB_DATA_CHANGED", "MB_DATA_UPDATED", "MB_DATA_INVALIDATED", "MB_DATA_ERROR",
        "MB_BOT_REGISTRY_READY", "MB_BOT_DISCOVERED", "MB_BOT_PRESENCE_CHANGED", "MB_BOT_LIFECYCLE_UPDATED",
        "MB_MANAGED_ROSTER_UPDATED", "MB_MANAGED_BOT_FORGOTTEN", "MB_SESSION_CHANGED",
    }
    for _, eventName in ipairs(events) do
        local token = API:Subscribe(MODULE, eventName, function(event, ...) BotInspect:OnCoreEvent(event, ...) end)
        if token then self.subscriptions[#self.subscriptions + 1] = token end
    end
    API:RegisterContextAction(MODULE, {
        id = "open_botinspect", contexts = { "BOT", "UNITFRAME" }, label = "Inspect Bot", order = 24,
        requirements = { bot = true },
        handler = function(context)
            local ref = context and (context.bot or context.botName or context.target)
            if ref then BotInspect:Open(ref) end
        end,
    })
    -- ContextMenu uses Core's existing contribution registry; no direct addon dependency.
    if type(self.RegisterQuestContextActions) == "function" then self:RegisterQuestContextActions() end
    local service = {}
    function service:Open(botRef) BotInspect:Open(botRef) end
    function service:Close() BotInspect:Close() end
    function service:GetSelectedBot() return BotInspect.selectedBot end
    API:RegisterService(MODULE, "BotInspect.Open", service)
end

function BotInspect:HandleSlash(input)
    input = trim(input)
    if input == "" then self:Toggle(); return end
    local command, rest = string.match(input, "^(%S+)%s*(.-)$")
    command = lower(command)
    if command == "show" or command == "open" then self:Open(rest ~= "" and rest or nil)
    elseif command == "hide" or command == "close" then self:Close()
    elseif command == "refresh" then self:RefreshAll()
    elseif command == "discover" or command == "find" then
        self:Open(); if rest ~= "" then self:DiscoverBot(rest, true) else self:SetStatus("Usage: /mbinspect discover <exact character name>", 0.90, 0.65, 0.35) end
    elseif command == "roster" then
        self:Open(); local db = self:GetSettings(); db.rosterExpanded = not (db.rosterExpanded ~= false); self:ApplyRosterExpanded()
    elseif command == "connect" and lower(rest) == "all" then
        self:Open(); self:ConnectAll()
    elseif command == "preset" then
        self:Open()
        if rest ~= "" then
            local name = self:FindGroupPresetName(rest)
            if name then self:SetActiveGroupPreset(name); self:SummonGroupPreset(name)
            else self:SetStatus("Unknown preset: " .. tostring(rest), 1, 0.55, 0.35) end
        else
            self:SetStatus("Choose a preset from the roster panel, or use /mbinspect preset <name>.", 0.45, 0.82, 1.0)
        end
    elseif command == "perf" then
        local jobs = 0; for _ in pairs(self.scheduledJobs or {}) do jobs = jobs + 1 end
        print(PREFIX .. string.format(" perf: bulkLifecycle=%s lifecyclePending=%d autoResolve=%d/%d history=%d/%d selectedRetries=%d scheduled=%d backgroundAllowed=%s",
            tostring(self.bulkLifecycleRunning == true),
            (function() local n=0; for _ in pairs(self.lifecyclePending or {}) do n=n+1 end; return n end)(),
            tonumber(self.autoResolveActive) or 0, #(self.autoResolveQueue or {}),
            tonumber(self.historyPrimeActive) or 0, #(self.historyPrimeQueue or {}),
            (function() local n=0; for _ in pairs(self.selectedRetryAttempts or {}) do n=n+1 end; return n end)(),
            jobs, tostring(self:BackgroundWorkAllowed())))
    elseif command == "summon" then
        if rest ~= "" and lower(rest) ~= "all" then self:SummonBot(rest)
        elseif self.selectedBot then self:SummonBot(self.selectedBot)
        else self:SetStatus("Usage: /mbinspect summon <bot>", 0.90, 0.65, 0.35) end
    else
        local managed = API:GetManagedBot(input); local bot = API:ResolveBot(input)
        if managed or (bot and bot.online == true) then self:Open((managed and managed.name) or bot.name)
        else print(PREFIX .. " Unknown managed bot: " .. input .. ". Use /mbinspect discover <exact name>.") end
    end
end

function BotInspect:Initialize()
    if self.initialized then return true end

    -- ElvUI profile-backed UI is valid only after E:Initialize() has built AceDB.
    if not E or E.data == nil or type(E.db) ~= "table" then
        return false, "ELVUI_NOT_READY"
    end

    self:InitializeSettings()
    self:RegisterElvUIProfileCallbacks()
    local coreVersion = API:GetCoreVersion() or "0.0.0"
    if not versionAtLeast(coreVersion, MIN_CORE)
        or not API:GetDomainDescriptor("BOT.EQUIPMENT")
        or not API:GetDomainDescriptor("BOT.SPELLBOOK")
        or type(API.GetLastKnown) ~= "function"
        or type(API.GetManagedRosterView) ~= "function"
        or type(API.GetForgetManagedBotAvailability) ~= "function"
        or type(API.ForgetManagedBot) ~= "function"
        or type(API.GetBotSpellEnabled) ~= "function"
        or type(API.GetBotSpellEnabledAvailability) ~= "function"
        or type(API.SetBotSpellEnabled) ~= "function"
        or type(API.GetBotSpellCastAvailability) ~= "function"
        or type(API.CastBotSpell) ~= "function"
        or type(API.GetBotSpellActionContract) ~= "function"
        or type(API.GetInventoryMoveAvailability) ~= "function"
or type(API.ExecuteInventoryMove) ~= "function"
        or type(API.GetQuestView) ~= "function"
        or type(API.ExecuteQuestAction) ~= "function"
        or type(API.RefreshQuestMetadata) ~= "function"
        or type(API.GetQuestNpcActionAvailability) ~= "function"
        or type(API.ExecuteQuestNpcAction) ~= "function" then
        print(PREFIX .. " requires ElvUI_Multibot_Core " .. MIN_CORE .. " or newer. Loaded: " .. tostring(coreVersion)); return false, "CORE_INCOMPATIBLE"
    end

    self.initialized = true
    if type(self.RegisterOptionsPlugin) == "function" then self:RegisterOptionsPlugin() end
    self:RegisterCoreIntegration(); self:CreateUI(); if type(self.InitializeMasterLootEnhancements) == "function" then self:InitializeMasterLootEnhancements() end; if type(self.InitializeMicroBarIntegration) == "function" then self:InitializeMicroBarIntegration() end; if type(self.InitializeHotkeyIntegration) == "function" then self:InitializeHotkeyIntegration() end; self:RefreshBotList()
    SLASH_ELVUIMULTIBOTBOTINSPECT1 = "/mbinspect"
    SLASH_ELVUIMULTIBOTBOTINSPECT2 = "/botinspect"
    SlashCmdList.ELVUIMULTIBOTBOTINSPECT = function(input) BotInspect:HandleSlash(input) end
    self.enabled = true
    print(PREFIX .. " " .. VERSION .. " loaded. Use /mbinspect.")
    return true
end

StaticPopupDialogs = StaticPopupDialogs or {}
StaticPopupDialogs["ELVUI_MULTIBOT_BOTINSPECT_DESTROY"] = {
    text = "Destroy %s? This cannot be undone.",
    button1 = YES or "Yes", button2 = NO or "No",
    OnAccept = function(self)
        local data = self and self.data
        if data and data.item then BotInspect:ExecuteInventoryAction("DESTROY", data.item, true) end
    end,
    timeout = 0, whileDead = 1, hideOnEscape = 1, preferredIndex = 3,
}

StaticPopupDialogs["ELVUI_MULTIBOT_BOTINSPECT_FORGET_ROSTER"] = {
    text = "Forget %s from Core?\n\nThis removes Core saved identity/history, snapshots and Managed Group membership for this bot. It does not delete or unlink the server character. Rediscovery remains possible.",
    button1 = YES or "Yes", button2 = NO or "No",
    OnAccept = function(self)
        local data = self and self.data
        if data and data.bot then BotInspect:ForgetRosterBot(data.bot) end
    end,
    timeout = 0, whileDead = 1, hideOnEscape = 1, preferredIndex = 3,
}

StaticPopupDialogs["ELVUI_MULTIBOT_BOTINSPECT_SAVE_GROUP_PRESET"] = {
    text = "Save the current Playerbot party/raid as a summon preset.\n\nUsing an existing name updates that preset. If no Playerbots are grouped, an empty preset is created for manual Ctrl+click editing.",
    button1 = ACCEPT or "Save", button2 = CANCEL or "Cancel",
    hasEditBox = 1, maxLetters = 24,
    OnShow = function(self)
        local data = self and self.data or {}
        if self.editBox then self.editBox:SetText(tostring(data.initialName or "")); self.editBox:HighlightText(); self.editBox:SetFocus() end
    end,
    OnAccept = function(self)
        local data = self and self.data or {}
        local name = self and self.editBox and self.editBox:GetText() or ""
        BotInspect:SaveGroupPreset(name, data.members or {})
    end,
    EditBoxOnEscapePressed = function(self) local parent = self:GetParent(); if parent then parent:Hide() end end,
    timeout = 0, whileDead = 1, hideOnEscape = 1, preferredIndex = 3,
}

StaticPopupDialogs["ELVUI_MULTIBOT_BOTINSPECT_RENAME_GROUP_PRESET"] = {
    text = "Rename preset %s:",
    button1 = ACCEPT or "Rename", button2 = CANCEL or "Cancel",
    hasEditBox = 1, maxLetters = 24,
    OnShow = function(self)
        local data = self and self.data or {}
        if self.editBox then self.editBox:SetText(tostring(data.initialName or "")); self.editBox:HighlightText(); self.editBox:SetFocus() end
    end,
    OnAccept = function(self)
        local data = self and self.data or {}
        local name = self and self.editBox and self.editBox:GetText() or ""
        BotInspect:RenameGroupPreset(data.oldName, name)
    end,
    EditBoxOnEscapePressed = function(self) local parent = self:GetParent(); if parent then parent:Hide() end end,
    timeout = 0, whileDead = 1, hideOnEscape = 1, preferredIndex = 3,
}

StaticPopupDialogs["ELVUI_MULTIBOT_BOTINSPECT_DELETE_GROUP_PRESET"] = {
    text = "Delete summon preset %s?",
    button1 = YES or "Yes", button2 = NO or "No",
    OnAccept = function(self)
        local data = self and self.data
        if data and data.name then BotInspect:DeleteGroupPreset(data.name) end
    end,
    timeout = 0, whileDead = 1, hideOnEscape = 1, preferredIndex = 3,
}

local eventFrame = CreateFrame("Frame")
pcall(eventFrame.RegisterEvent, eventFrame, "MERCHANT_SHOW")
pcall(eventFrame.RegisterEvent, eventFrame, "MERCHANT_CLOSED")
local itemInfoEventOK = pcall(eventFrame.RegisterEvent, eventFrame, "GET_ITEM_INFO_RECEIVED")
eventFrame:SetScript("OnEvent", function(_, event, ...)
    if itemInfoEventOK and event == "GET_ITEM_INFO_RECEIVED" and BotInspect.enabled and BotInspect.frame and BotInspect.frame:IsShown() then
        BotInspect:RenderInventory()
        BotInspect:RenderEquipment()
    elseif (event == "MERCHANT_SHOW" or event == "MERCHANT_CLOSED") and BotInspect.enabled and BotInspect.frame and BotInspect.frame:IsShown() then
        if event == "MERCHANT_CLOSED" and BotInspect.defaultInventoryAction == "SELL" then
            BotInspect.defaultInventoryAction = nil
        end
        BotInspect:RenderInventoryActionStrip()
    end
end)
BotInspect.eventFrame = eventFrame

-- Follow ElvUI 6.09's own lifecycle. Core is a RequiredDep and registers its
-- post-initialize hook before this addon, so by the time our hook runs both
-- ElvUI's AceDB objects and the Core API are ready.
local EP = LibStub and LibStub("LibElvUIPlugin-1.0", true)
if E and E.data and E.db then
    BotInspect:Initialize() -- late/manual load after ElvUI is already initialized
elseif EP and type(EP.HookInitialize) == "function" then
    EP:HookInitialize(BotInspect, "Initialize")
else
    error("ElvUI_Multibot_BotInspect requires ElvUI 6.09 with LibElvUIPlugin-1.0")
end
