local addonName = ...

local MODULE = "ElvUI_Multibot_ContextMenu"
local VERSION = GetAddOnMetadata(addonName, "Version") or "0.1.0-alpha22.1"
local PREFIX = "|cff1784d1Multibot|r"

local E, L, V, P, G
if type(ElvUI) == "table" and type(unpack) == "function" then
    E, L, V, P, G = unpack(ElvUI)
end

local DEFAULT_SETTINGS = {
    worldScale = 1.00,
    unitFrameScale = 1.00,
    backgroundColor = { r = 0.08, g = 0.08, b = 0.08 },
    backgroundTransparency = 8,
    textSize = 12,
    hoverGrace = 2.00,
    worldBotMode = "OUT_OF_COMBAT",
}

-- ElvUI 6.09 builds its AceDB profile from P during E:Initialize(). Register
-- ContextMenu defaults while addon files are loading, but do not bind E.db or
-- initialize runtime services until ElvUI's post-initialize lifecycle fires.
if type(P) == "table" then
    P.multibotContextMenu = type(P.multibotContextMenu) == "table" and P.multibotContextMenu or {}
    local profileDefaults = P.multibotContextMenu
    if profileDefaults.worldScale == nil then profileDefaults.worldScale = DEFAULT_SETTINGS.worldScale end
    if profileDefaults.unitFrameScale == nil then profileDefaults.unitFrameScale = DEFAULT_SETTINGS.unitFrameScale end
    if profileDefaults.backgroundTransparency == nil then profileDefaults.backgroundTransparency = DEFAULT_SETTINGS.backgroundTransparency end
    if profileDefaults.textSize == nil then profileDefaults.textSize = DEFAULT_SETTINGS.textSize end
    if profileDefaults.hoverGrace == nil then profileDefaults.hoverGrace = DEFAULT_SETTINGS.hoverGrace end
    if profileDefaults.worldBotMode == nil then profileDefaults.worldBotMode = DEFAULT_SETTINGS.worldBotMode end
    if type(profileDefaults.backgroundColor) ~= "table" then
        profileDefaults.backgroundColor = {
            r = DEFAULT_SETTINGS.backgroundColor.r,
            g = DEFAULT_SETTINGS.backgroundColor.g,
            b = DEFAULT_SETTINGS.backgroundColor.b,
        }
    else
        if profileDefaults.backgroundColor.r == nil then profileDefaults.backgroundColor.r = DEFAULT_SETTINGS.backgroundColor.r end
        if profileDefaults.backgroundColor.g == nil then profileDefaults.backgroundColor.g = DEFAULT_SETTINGS.backgroundColor.g end
        if profileDefaults.backgroundColor.b == nil then profileDefaults.backgroundColor.b = DEFAULT_SETTINGS.backgroundColor.b end
    end
end

local ContextMenu = {
    enabled = false,
    initialized = false,
    profileCallbacksRegistered = false,
    optionsPluginRegistered = false,
    api = nil,
    core = nil,
    bindingInstalled = false,
    bindingError = nil,
    captureEnabled = true,
    sequence = 0,
    last = nil,
    history = {},
    maxHistory = 20,
    pending = nil,
    hookedUnitFrames = setmetatable({}, { __mode = "k" }),
    hookedUnitFrameCount = 0,
    lastScanCandidates = 0,
    suppressedUnitFrames = setmetatable({}, { __mode = "k" }),
    unitFrameSuppressionCount = 0,
    unitFrameSuppressionError = nil,
    menuFrame = nil,
    menuAnchor = nil,
    activeMenu = nil,
    ownMenuOpening = false,
    menuOpenCount = 0,
    subscriptions = {},
    rtscKnownSlots = {},
    rtscPlacement = nil,
    rtscEnableRequest = nil,
    rtscEnableObserved = false,
    rtscSecureButtons = {},
    rtscSecureRows = {},
    delayedTasks = {},
    db = nil,
    E = E,
    P = P,
    menuFonts = {},
    strategyInterestBot = nil,
}

_G.ElvUI_Multibot_ContextMenu = ContextMenu

local INTERACTION_EVENTS = {
    GOSSIP_SHOW = true,
    MERCHANT_SHOW = true,
    QUEST_GREETING = true,
    TRAINER_SHOW = true,
    BANKFRAME_OPENED = true,
    GUILDBANKFRAME_OPENED = true,
    TAXIMAP_OPENED = true,
    AUCTION_HOUSE_SHOW = true,
    PET_STABLE_SHOW = true,
}

-- ContextMenu deliberately exposes a conservative, gameplay-useful subset of
-- Playerbots strategies. Role/spec filtering is applied at render time, and
-- BOT.STATE remains authoritative for active highlighting. Raid-instance
-- strategies are intentionally omitted because Playerbots handles them
-- automatically on the target server.
local STRATEGY_GREEN = "|cff40ff40"
local STRATEGY_RESET = "|r"

local NC_STRATEGIES = {
    { key = "food", label = "Food / Drink", tooltip = "Allow normal eating and drinking behavior." },
    { key = "pvp", label = "PvP", tooltip = "Toggle the bot's non-combat PvP strategy." },
    { key = "loot", label = "Loot", tooltip = "Allow normal Playerbots looting behavior." },
}

local CO_COMMON = {
    { key = "assist", label = "Assist", tooltip = "Focus normal combat targeting around an assisted target." },
    { key = "boost", label = "Boost", tooltip = "Allow major cooldown / burst usage." },
    { key = "focus", label = "Focus", tooltip = "Prefer focused single-target behavior over spreading effects." },
    { key = "avoid aoe", label = "Avoid AoE", tooltip = "Avoid harmful area effects when Playerbots can detect them." },
    { key = "wait for attack", label = "Wait for Attack", tooltip = "Use the configured Playerbots attack-delay behavior." },
    { key = "mark rti", label = "Mark RTI", tooltip = "Allow the bot to automatically mark an unmarked attacker with its priority RTI icon." },
}

local CO_BY_ROLE = {
    TANK = {
        { key = "tank", label = "Tank" },
        { key = "tank assist", label = "Tank Assist" },
        { key = "aoe", label = "AoE" },
        { key = "tank face", label = "Tank Face" },
        { key = "pull", label = "Pull" },
        { key = "pull back", label = "Pull Back" },
    },
    DPS = {
        { key = "dps", label = "DPS" },
        { key = "aoe", label = "AoE" },
        { key = "threat", label = "Threat" },
    },
    HEALER = {
        { key = "heal", label = "Heal" },
        { key = "save mana", label = "Save Mana" },
        { key = "healer dps", label = "Healer DPS" },
    },
}

local CLASS_STRATEGIES = {
    PRIEST = {
        { key = "rshadow", label = "Shadow Protection", scope = "N" },
    },
    PALADIN = {
        { key = "bdps", label = "Blessing: DPS", scope = "N" },
        { key = "bmana", label = "Blessing: Mana", scope = "N" },
        { key = "bstats", label = "Blessing: Stats", scope = "N" },
        { key = "bhealth", label = "Blessing: Health", scope = "N" },
        { key = "rfire", label = "Aura: Fire Resistance", scope = "N" },
        { key = "rfrost", label = "Aura: Frost Resistance", scope = "N" },
        { key = "rshadow", label = "Aura: Shadow Resistance", scope = "N" },
        { key = "baoe", label = "Aura: Retribution", scope = "N" },
        { key = "barmor", label = "Aura: Devotion", scope = "N" },
        { key = "bcast", label = "Aura: Concentration", scope = "N" },
        { key = "bspeed", label = "Aura: Crusader", scope = "N" },
    },
    HUNTER = {
        { key = "trap weave", label = "Trap Weave", scope = "C" },
        { key = "bdps", label = "Aspect: DPS", scope = "N" },
        { key = "bspeed", label = "Aspect: Speed", scope = "N" },
        { key = "bmana", label = "Aspect: Mana", scope = "N" },
        { key = "rnature", label = "Aspect: Nature Resistance", scope = "N" },
    },
    WARLOCK = {
        { key = "meta melee", label = "Meta Melee", scope = "C", spec = "Demonology" },
        { key = "imp", label = "Pet: Imp", scope = "N" },
        { key = "voidwalker", label = "Pet: Voidwalker", scope = "N" },
        { key = "succubus", label = "Pet: Succubus", scope = "N" },
        { key = "felhunter", label = "Pet: Felhunter", scope = "N" },
        { key = "felguard", label = "Pet: Felguard", scope = "N" },
        { key = "ss master", label = "Soulstone: Master", scope = "N" },
        { key = "ss self", label = "Soulstone: Self", scope = "N" },
        { key = "ss tank", label = "Soulstone: Tank", scope = "N" },
        { key = "ss healer", label = "Soulstone: Healer", scope = "N" },
    },
    MAGE = {
        { key = "frost", label = "Frost", scope = "C", spec = "Frost" },
        { key = "fire", label = "Fire", scope = "C", spec = "Fire" },
        { key = "firestarter", label = "Firestarter", scope = "C", spec = "Fire" },
    },
    DRUID = {
        { key = "bear", label = "Bear", scope = "C", druidRole = "TANK" },
        { key = "cat", label = "Cat", scope = "C", druidRole = "DPS" },
        { key = "caster", label = "Caster", scope = "C", specs = { Balance = true, Restoration = true } },
        { key = "feral charge", label = "Feral Charge", scope = "C", spec = "Feral" },
        { key = "tranquility", label = "Tranquility", scope = "C", spec = "Restoration" },
        { key = "blanketing", label = "Blanketing", scope = "C", spec = "Restoration" },
    },
}

local CC_STRATEGY_CLASSES = {
    MAGE = true, HUNTER = true, PRIEST = true, DRUID = true,
    WARLOCK = true, SHAMAN = true,
}

local function trim(value)
    value = tostring(value or "")
    return (string.gsub(value, "^%s*(.-)%s*$", "%1"))
end

local function boolText(value)
    return value and "yes" or "no"
end

local function safeCall(object, method, ...)
    if not object then return nil end
    local fn = object[method]
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c, d = pcall(fn, object, ...)
    if not ok then return nil end
    return a, b, c, d
end

local function clamp(value, minimum, maximum)
    value = tonumber(value) or minimum
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function copyColor(source, fallback)
    source = type(source) == "table" and source or fallback
    return {
        r = clamp(source and source.r or fallback.r, 0, 1),
        g = clamp(source and source.g or fallback.g, 0, 1),
        b = clamp(source and source.b or fallback.b, 0, 1),
    }
end

function ContextMenu:InitializeSettings()
    local elv = self.E or E
    self.E = elv
    if not elv or type(elv.data) ~= "table" or type(elv.db) ~= "table" then
        return nil, "ELVUI_PROFILE_NOT_READY"
    end

    elv.db.multibotContextMenu = type(elv.db.multibotContextMenu) == "table" and elv.db.multibotContextMenu or {}
    local db = elv.db.multibotContextMenu

    -- `next` and `rawget` intentionally inspect only values actually stored in
    -- this profile. ElvUI's AceDB defaults live behind a metatable, and Alpha20
    -- deliberately migrated pre-worldBotMode profiles to ENABLED while truly
    -- fresh profiles default to OUT_OF_COMBAT. Preserve that behavior exactly.
    local hadExistingProfileSettings = next(db) ~= nil
    local legacyScale = rawget and rawget(db, "scale") or db.scale
    if rawget(db, "worldScale") == nil then db.worldScale = legacyScale or DEFAULT_SETTINGS.worldScale end
    if rawget(db, "unitFrameScale") == nil then db.unitFrameScale = legacyScale or DEFAULT_SETTINGS.unitFrameScale end
    if rawget(db, "backgroundTransparency") == nil then db.backgroundTransparency = DEFAULT_SETTINGS.backgroundTransparency end
    if rawget(db, "textSize") == nil then db.textSize = DEFAULT_SETTINGS.textSize end
    if rawget(db, "hoverGrace") == nil then db.hoverGrace = DEFAULT_SETTINGS.hoverGrace end
    if rawget(db, "worldBotMode") == nil then
        db.worldBotMode = hadExistingProfileSettings and "ENABLED" or DEFAULT_SETTINGS.worldBotMode
    end
    if db.worldBotMode ~= "DISABLED" and db.worldBotMode ~= "ENABLED" and db.worldBotMode ~= "OUT_OF_COMBAT" then
        db.worldBotMode = DEFAULT_SETTINGS.worldBotMode
    end
    db.backgroundColor = copyColor(db.backgroundColor, DEFAULT_SETTINGS.backgroundColor)

    db.worldScale = clamp(db.worldScale, 0.65, 1.75)
    db.unitFrameScale = clamp(db.unitFrameScale, 0.65, 1.75)
    db.backgroundTransparency = clamp(db.backgroundTransparency, 0, 100)
    db.textSize = clamp(db.textSize, 8, 18)
    db.hoverGrace = clamp(db.hoverGrace, 0, 5)

    self.db = db
    return db
end

function ContextMenu:GetSettings()
    local elv = self.E or E
    if elv and type(elv.data) == "table" and type(elv.db) == "table" then
        local current = elv.db.multibotContextMenu
        if type(current) ~= "table" or current ~= self.db then
            local db = self:InitializeSettings()
            if db then return db end
        end
    end
    return self.db or DEFAULT_SETTINGS
end

function ContextMenu:OnElvUIProfileChanged()
    self.db = nil
    local db = self:InitializeSettings()
    if not db then return end
    if self.RefreshVisibleMenuPresentation then self:RefreshVisibleMenuPresentation() end
end

function ContextMenu:RegisterElvUIProfileCallbacks()
    if self.profileCallbacksRegistered then return true end
    local data = self.E and self.E.data
    if not data or type(data.RegisterCallback) ~= "function" then
        return false, "ELVUI_PROFILE_CALLBACKS_UNAVAILABLE"
    end

    data.RegisterCallback(self, "OnProfileChanged", "OnElvUIProfileChanged")
    data.RegisterCallback(self, "OnProfileCopied", "OnElvUIProfileChanged")
    data.RegisterCallback(self, "OnProfileReset", "OnElvUIProfileChanged")
    self.profileCallbacksRegistered = true
    return true
end

function ContextMenu:GetMenuScale(contextKind)
    local db = self:GetSettings()
    contextKind = contextKind or (self.activeMenu and self.activeMenu.entry and self.activeMenu.entry.context and self.activeMenu.entry.context.contextKind)
    if contextKind == "BOT_FRAME" or contextKind == "WORLD_BOT" then
        return clamp(db.unitFrameScale, 0.65, 1.75)
    end
    return clamp(db.worldScale, 0.65, 1.75)
end

function ContextMenu:GetWorldMenuScale()
    return clamp(self:GetSettings().worldScale, 0.65, 1.75)
end

function ContextMenu:GetUnitFrameMenuScale()
    return clamp(self:GetSettings().unitFrameScale, 0.65, 1.75)
end

function ContextMenu:GetMenuBackgroundColor()
    local c = copyColor(self:GetSettings().backgroundColor, DEFAULT_SETTINGS.backgroundColor)
    local alpha = 1 - (clamp(self:GetSettings().backgroundTransparency, 0, 100) / 100)
    return c.r, c.g, c.b, alpha
end

function ContextMenu:GetMenuTextSize()
    return clamp(self:GetSettings().textSize, 8, 18)
end

function ContextMenu:GetHoverGracePeriod()
    return clamp(self:GetSettings().hoverGrace, 0, 5)
end

function ContextMenu:GetWorldBotMode()
    local mode = self:GetSettings().worldBotMode
    if mode ~= "DISABLED" and mode ~= "ENABLED" and mode ~= "OUT_OF_COMBAT" then
        mode = DEFAULT_SETTINGS.worldBotMode
    end
    return mode
end

function ContextMenu:IsWorldBotMenuAllowed()
    local mode = self:GetWorldBotMode()
    if mode == "DISABLED" then return false, "WORLD_BOT_DISABLED" end
    if mode == "OUT_OF_COMBAT" and InCombatLockdown and InCombatLockdown() then
        return false, "WORLD_BOT_COMBAT_DISABLED"
    end
    return true
end

function ContextMenu:IsMenuEligibleContext(kind)
    if kind == "BOT_FRAME" or kind == "WORLD_EMPTY" then return true end
    if kind == "WORLD_BOT" then
        return self:IsWorldBotMenuAllowed()
    end
    return false
end

function ContextMenu:NeedsPrimarySnapshot(kind)
    -- World NPC/player classifications are deliberately inert future-facing
    -- observations. Do not touch Core selection state for those gestures.
    if kind == "WORLD_EMPTY" or kind == "BOT_FRAME" then return true end
    if kind == "WORLD_BOT" then
        local allowed = self:IsWorldBotMenuAllowed()
        return allowed == true
    end
    return false
end

function ContextMenu:GetSizedMenuFont(kind)
    kind = kind or "normal"
    local font = self.menuFonts[kind]
    if not font and type(CreateFont) == "function" then
        font = CreateFont(MODULE .. "_MenuFont_" .. tostring(kind))
        self.menuFonts[kind] = font
    end
    if not font then return nil end

    local base
    if kind == "title" then
        base = _G.GameFontNormalSmall or _G.GameFontNormal
    elseif kind == "disabled" then
        base = _G.GameFontDisableSmall or _G.GameFontDisable or _G.GameFontNormalSmall
    else
        base = _G.GameFontHighlightSmall or _G.GameFontHighlight or _G.GameFontNormalSmall
    end

    if base and type(font.SetFontObject) == "function" then pcall(font.SetFontObject, font, base) end
    if base and type(base.GetFont) == "function" and type(font.SetFont) == "function" then
        local path, _, flags = base:GetFont()
        if path then pcall(font.SetFont, font, path, self:GetMenuTextSize(), flags) end
    end
    return font
end

function ContextMenu:IsOwnMenuOpen()
    if self.menuFrame and _G.UIDROPDOWNMENU_OPEN_MENU == self.menuFrame then return true end
    local list = _G.DropDownList1
    return self.activeMenu ~= nil and list and type(list.IsShown) == "function" and list:IsShown()
end

function ContextMenu:ApplyGraceToList(list)
    if not list then return end
    if not list.mbcmGraceHooked and type(list.HookScript) == "function" then
        list.mbcmGraceHooked = true
        list:HookScript("OnEnter", function(frame)
            if ContextMenu:IsOwnMenuOpen() then
                frame.showTimer = nil
                if type(UIDropDownMenu_StopCounting) == "function" then UIDropDownMenu_StopCounting(frame) end
            end
        end)
        list:HookScript("OnLeave", function(frame)
            if ContextMenu:IsOwnMenuOpen() then frame.showTimer = ContextMenu:GetHoverGracePeriod() end
        end)
    end
end

function ContextMenu:ApplyGraceToButton(button, list)
    if not button or button.mbcmGraceHooked or type(button.HookScript) ~= "function" then return end
    button.mbcmGraceHooked = true
    button:HookScript("OnEnter", function()
        if ContextMenu:IsOwnMenuOpen() and list then
            list.showTimer = nil
            if type(UIDropDownMenu_StopCounting) == "function" then UIDropDownMenu_StopCounting(list) end
        end
    end)
    button:HookScript("OnLeave", function()
        if ContextMenu:IsOwnMenuOpen() and list then list.showTimer = ContextMenu:GetHoverGracePeriod() end
    end)
end

function ContextMenu:StyleMenuBackdrop(frame)
    if not frame then return end
    local r, g, b, a = self:GetMenuBackgroundColor()
    if type(frame.SetBackdropColor) == "function" then
        pcall(frame.SetBackdropColor, frame, r, g, b, a)
    elseif type(frame.SetAlpha) == "function" then
        pcall(frame.SetAlpha, frame, a)
    end
end

function ContextMenu:StyleMenuButton(button)
    if not button then return end
    local text = type(button.GetFontString) == "function" and button:GetFontString() or nil
    if not text and type(button.GetName) == "function" then
        local name = button:GetName()
        if name then text = _G[name .. "NormalText"] end
    end
    if text and type(text.GetFont) == "function" and type(text.SetFont) == "function" then
        local path, _, flags = text:GetFont()
        if path then pcall(text.SetFont, text, path, self:GetMenuTextSize(), flags) end
    end
end

function ContextMenu:ApplyMenuPresentation(level, skipScale)
    level = tonumber(level) or 1
    local list = _G["DropDownList" .. tostring(level)]
    if not list then return end

    if not skipScale and type(list.SetScale) == "function" then pcall(list.SetScale, list, self:GetMenuScale()) end
    self:StyleMenuBackdrop(list)
    self:StyleMenuBackdrop(_G["DropDownList" .. tostring(level) .. "Backdrop"])
    self:StyleMenuBackdrop(_G["DropDownList" .. tostring(level) .. "MenuBackdrop"])
    self:ApplyGraceToList(list)

    local count = tonumber(list.numButtons) or 0
    for index = 1, count do
        local button = _G["DropDownList" .. tostring(level) .. "Button" .. tostring(index)]
        if button then
            self:StyleMenuButton(button)
            self:ApplyGraceToButton(button, list)
        end
    end
end

function ContextMenu:RefreshVisibleMenuPresentation()
    self:GetSizedMenuFont("normal")
    self:GetSizedMenuFont("title")
    self:GetSizedMenuFont("disabled")
    local maxLevels = tonumber(_G.UIDROPDOWNMENU_MAXLEVELS) or 3
    if maxLevels < 3 then maxLevels = 3 end
    if maxLevels > 8 then maxLevels = 8 end
    for level = 1, maxLevels do self:ApplyMenuPresentation(level) end
end

local function join(list, separator)
    local out = ""
    separator = separator or ", "
    for index, value in ipairs(list or {}) do
        if index > 1 then out = out .. separator end
        out = out .. tostring(value)
    end
    return out
end

function ContextMenu:Print(message)
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. " " .. tostring(message))
    end
end

function ContextMenu:GetModifierLabel()
    local ctrl = IsControlKeyDown and IsControlKeyDown()
    local shift = IsShiftKeyDown and IsShiftKeyDown()
    if ctrl and shift then return "CTRL+SHIFT" end
    if ctrl then return "CTRL" end
    if shift then return "SHIFT" end
    return "NONE"
end

function ContextMenu:GetPrimarySnapshot()
    if not self.api or type(self.api.GetSelection) ~= "function" then
        return { count = 0, names = {}, ready = false }
    end

    local selection = self.api:GetSelection("PRIMARY") or {}
    local names = {}
    for _, bot in ipairs(selection.bots or {}) do
        if bot and bot.name then names[#names + 1] = bot.name end
    end
    table.sort(names)

    return {
        count = tonumber(selection.count) or #names,
        names = names,
        revision = selection.revision,
        ready = true,
    }
end

function ContextMenu:FindUnitFrame(frame)
    local current = frame
    local depth = 0

    while current and depth < 16 do
        depth = depth + 1

        local unit = nil
        if type(current.unit) == "string" and current.unit ~= "" then
            unit = current.unit
        end

        if not unit and current.GetAttribute then
            local value = safeCall(current, "GetAttribute", "unit")
            if type(value) == "string" and value ~= "" then unit = value end
        end

        if unit and UnitExists and UnitExists(unit) then
            return current, unit, depth
        end

        if current.GetParent then
            current = current:GetParent()
        else
            current = nil
        end
    end

    return nil, nil, depth
end

function ContextMenu:GetFrameInfo(frame)
    if not frame then
        return { name = "<nil>", objectType = "<nil>" }
    end

    local name = safeCall(frame, "GetName")
    local objectType = safeCall(frame, "GetObjectType")
    return {
        name = name or "<unnamed>",
        objectType = objectType or "<unknown>",
    }
end

function ContextMenu:GetUnitInfo(unit)
    if not unit or not UnitExists or not UnitExists(unit) then return nil end

    local name = UnitName and UnitName(unit) or nil
    local guid = UnitGUID and UnitGUID(unit) or nil
    local classLocal, classFile = nil, nil
    if UnitClass then classLocal, classFile = UnitClass(unit) end
    local isPlayer = UnitIsPlayer and UnitIsPlayer(unit) and true or false
    local playerControlled = UnitPlayerControlled and UnitPlayerControlled(unit) and true or false
    local canAttack = UnitCanAttack and UnitCanAttack("player", unit) and true or false
    local isFriend = UnitIsFriend and UnitIsFriend("player", unit) and true or false
    local reaction = UnitReaction and UnitReaction(unit, "player") or nil

    local disposition = "UNKNOWN"
    if reaction then
        if reaction <= 3 then disposition = "HOSTILE"
        elseif reaction == 4 then disposition = "NEUTRAL"
        elseif reaction >= 5 then disposition = "FRIENDLY" end
    elseif isFriend then
        disposition = "FRIENDLY"
    elseif canAttack then
        disposition = "HOSTILE"
    end

    local kind = "NPC"
    if isPlayer then
        kind = "PLAYER"
    elseif playerControlled then
        kind = "PLAYER_CONTROLLED"
    end

    return {
        unit = unit,
        name = name,
        guid = guid,
        classLocal = classLocal,
        classFile = classFile,
        kind = kind,
        isPlayer = isPlayer,
        playerControlled = playerControlled,
        canAttack = canAttack,
        isFriend = isFriend,
        reaction = reaction,
        disposition = disposition,
    }
end

function ContextMenu:IsExplicitBotContext(kind)
    return kind == "BOT_FRAME" or kind == "WORLD_BOT"
end

function ContextMenu:IsWorldUnitContext(kind)
    return kind == "WORLD_BOT" or kind == "WORLD_UNIT_ATTACKABLE" or kind == "WORLD_UNIT_FRIENDLY" or kind == "WORLD_UNIT_OTHER"
end

function ContextMenu:IsWorldSelectionContext(kind)
    -- Only empty-world Shift+RMB is an active PRIMARY control surface. Ordinary
    -- world units remain classified for future bridge capabilities but are inert.
    return kind == "WORLD_EMPTY"
end

function ContextMenu:GetWorldUnitContextKind(info)
    if not info then return "WORLD_UNIT_OTHER" end
    -- Combat eligibility is the important distinction for contextual actions.
    -- Neutral and hostile units intentionally collapse together when WoW reports
    -- that the player can attack them.
    if info.canAttack then return "WORLD_UNIT_ATTACKABLE" end
    if info.isFriend or info.disposition == "FRIENDLY" then return "WORLD_UNIT_FRIENDLY" end
    return "WORLD_UNIT_OTHER"
end

function ContextMenu:ResolveContext(source, explicitFrame)
    local focus = explicitFrame or (GetMouseFocus and GetMouseFocus() or nil)
    local frameInfo = self:GetFrameInfo(focus)
    local unitFrame, frameUnit, frameDepth = self:FindUnitFrame(focus)

    local context = {
        source = source,
        focus = focus,
        focusName = frameInfo.name,
        focusType = frameInfo.objectType,
        frameDepth = frameDepth,
        contextKind = "UI_OTHER",
        unit = nil,
        bot = nil,
        botResolved = false,
    }

    if unitFrame and frameUnit then
        local info = self:GetUnitInfo(frameUnit)
        context.unitFrame = unitFrame
        context.unit = info
        local isSelf = UnitIsUnit and UnitIsUnit(frameUnit, "player") and true or false
        if not isSelf and info and info.name and self.api and type(self.api.ResolveBot) == "function" then
            local bot = self.api:ResolveBot(info.name)
            if bot then
                context.bot = bot
                context.botResolved = true
                context.contextKind = "BOT_FRAME"
            else
                context.contextKind = "UNITFRAME_NONBOT"
            end
        else
            context.contextKind = "UNITFRAME_NONBOT"
        end
        return context
    end

    local focusIsWorld = focus == WorldFrame or frameInfo.name == "WorldFrame"
    if focusIsWorld or focus == nil then
        if UnitExists and UnitExists("mouseover") then
            context.unit = self:GetUnitInfo("mouseover")

            -- A Playerbot in the 3D world is still a PLAYER unit to the WoW client.
            -- Use Core identity resolution to distinguish it from human players and
            -- ordinary friendly NPCs. Self is explicitly excluded.
            local isSelf = UnitIsUnit and UnitIsUnit("mouseover", "player") and true or false
            if not isSelf and context.unit and context.unit.isPlayer and context.unit.name and
               self.api and type(self.api.ResolveBot) == "function" then
                local bot = self.api:ResolveBot(context.unit.name)
                if bot then
                    context.bot = bot
                    context.botResolved = true
                    context.contextKind = "WORLD_BOT"
                else
                    context.contextKind = self:GetWorldUnitContextKind(context.unit)
                end
            else
                context.contextKind = self:GetWorldUnitContextKind(context.unit)
            end
        else
            context.contextKind = "WORLD_EMPTY"
        end
    end

    return context
end

function ContextMenu:GetTargetSnapshot()
    if not UnitExists or not UnitExists("target") then
        return { exists = false, guid = nil, name = nil }
    end
    return {
        exists = true,
        guid = UnitGUID and UnitGUID("target") or nil,
        name = UnitName and UnitName("target") or nil,
    }
end

function ContextMenu:DescribePrimary(primary)
    local names = primary and primary.names or {}
    if #names == 0 then return "0 []" end
    return tostring(primary.count or #names) .. " [" .. join(names) .. "]"
end

function ContextMenu:DescribeUnit(unit)
    if not unit then return "none" end
    local name = unit.name or "<unnamed>"
    local disposition = unit.disposition or "UNKNOWN"
    local attackable = unit.canAttack and "attackable" or "not-attackable"
    return name .. "/" .. tostring(unit.kind or "UNIT") .. "/" .. disposition .. "/" .. attackable
end

function ContextMenu:GetContextBotName(context)
    if not context or not context.botResolved or not context.bot then return nil end
    return context.bot.name or context.bot.characterName or context.bot.ref
end

function ContextMenu:ColorizeBotName(context, botName)
    botName = tostring(botName or "<unknown>")
    local classFile = context and context.unit and context.unit.classFile or nil
    if not classFile and context and context.unit and context.unit.unit and UnitClass then
        local _, token = UnitClass(context.unit.unit)
        classFile = token
    end
    if not classFile and context and context.bot then
        classFile = context.bot.class or context.bot.className
        if type(classFile) == "string" then classFile = string.upper(classFile) end
    end
    local colors = _G.CUSTOM_CLASS_COLORS or _G.RAID_CLASS_COLORS
    local color = colors and classFile and colors[classFile] or nil
    if not color then return botName end
    local r = math.floor(clamp((tonumber(color.r) or 1) * 255, 0, 255) + 0.5)
    local g = math.floor(clamp((tonumber(color.g) or 1) * 255, 0, 255) + 0.5)
    local b = math.floor(clamp((tonumber(color.b) or 1) * 255, 0, 255) + 0.5)
    return string.format("|cff%02x%02x%02x%s|r", r, g, b, botName)
end

function ContextMenu:BuildContextData(entry)
    if not entry or not entry.context then return {} end
    local context = entry.context
    local data = {
        primarySelection = "PRIMARY",
        primaryCount = entry.primary and entry.primary.count or 0,
        source = context.contextKind,
    }

    if self:IsExplicitBotContext(context.contextKind) then
        data.bot = self:GetContextBotName(context)
        data.unit = context.unit and context.unit.unit or nil
        data.unitName = context.unit and context.unit.name or nil
        if context.contextKind == "WORLD_BOT" then
            data.worldUnit = {
                unit = context.unit and context.unit.unit or nil,
                name = context.unit and context.unit.name or nil,
                guid = context.unit and context.unit.guid or nil,
                disposition = context.unit and context.unit.disposition or nil,
                canAttack = context.unit and context.unit.canAttack or false,
                kind = context.unit and context.unit.kind or nil,
            }
        end
    elseif self:IsWorldUnitContext(context.contextKind) then
        -- Client-observed presentation context only. It is not manufactured into
        -- a Core action target by this renderer.
        data.worldUnit = {
            unit = context.unit and context.unit.unit or nil,
            name = context.unit and context.unit.name or nil,
            guid = context.unit and context.unit.guid or nil,
            disposition = context.unit and context.unit.disposition or nil,
            canAttack = context.unit and context.unit.canAttack or false,
            kind = context.unit and context.unit.kind or nil,
        }
    end
    return data
end

function ContextMenu:TreeHasChildren(tree)
    return type(tree) == "table" and type(tree.children) == "table" and #tree.children > 0
end

function ContextMenu:GetPreviewTrees(entry)
    if not self.api or type(self.api.GetContextTree) ~= "function" or not entry then return {} end
    local kind = entry.context and entry.context.contextKind or nil
    local contextData = self:BuildContextData(entry)
    local queries = {}

    if kind == "BOT_FRAME" or kind == "WORLD_BOT" then
        -- WORLD_BOT intentionally reuses the UnitFrame contribution set so the
        -- optional 3D-world bot menu stays functionally aligned with BOT_FRAME.
        -- contextData.source remains WORLD_BOT, so contributors can still tell
        -- which physical interaction surface opened the menu if they need to.
        queries[#queries + 1] = { contextType = "UNITFRAME", label = "UnitFrame contributions" }
    elseif kind == "WORLD_EMPTY" then
        queries[#queries + 1] = { contextType = "WORLD_SELECTION", label = "World selection contributions" }
        queries[#queries + 1] = { contextType = "SELECTION", label = "Selection contributions" }
    end

    local out = {}
    for _, query in ipairs(queries) do
        local ok, tree = pcall(self.api.GetContextTree, self.api, query.contextType, contextData)
        if ok and self:TreeHasChildren(tree) then
            out[#out + 1] = {
                contextType = query.contextType,
                label = query.label,
                tree = tree,
            }
        end
    end
    return out
end

function ContextMenu:AddMenuInfo(info, level)
    level = level or 1
    if type(UIDropDownMenu_AddButton) == "function" then
        if type(info) == "table" and not info.fontObject then
            local kind = info.isTitle and "title" or (info.disabled and "disabled" or "normal")
            info.fontObject = self:GetSizedMenuFont(kind)
        end
        UIDropDownMenu_AddButton(info, level)
        -- Style newly-added rows immediately, but defer scaling until Blizzard has
        -- finished positioning the dropdown level.
        self:ApplyMenuPresentation(level, true)
    end
end

function ContextMenu:AddDisabledLine(text, level, isTitle)
    if type(UIDropDownMenu_CreateInfo) ~= "function" then return end
    local info = UIDropDownMenu_CreateInfo()
    info.text = tostring(text or "")
    info.notCheckable = 1
    info.disabled = isTitle and nil or 1
    info.isTitle = isTitle and 1 or nil
    self:AddMenuInfo(info, level)
end

function ContextMenu:AddTreeNode(node, level)
    if type(node) ~= "table" or type(UIDropDownMenu_CreateInfo) ~= "function" then return end
    local info = UIDropDownMenu_CreateInfo()
    info.notCheckable = 1

    if node.type == "group" then
        info.text = tostring(node.label or node.id or "Group")
        info.hasArrow = 1
        info.value = { mbcmTreeNode = node }
        self:AddMenuInfo(info, level)
    elseif node.type == "action" then
        info.text = tostring(node.label or node.id or "Action")
        if node.enabled == false then
            info.disabled = 1
            if node.disabledReason then
                info.tooltipWhileDisabled = 1
                info.tooltipOnButton = 1
                info.tooltipTitle = info.text
                info.tooltipText = tostring(node.disabledReason)
            end
        elseif not node.contributionId then
            info.disabled = 1
            info.tooltipWhileDisabled = 1
            info.tooltipOnButton = 1
            info.tooltipTitle = info.text
            info.tooltipText = "Missing Core contribution id."
        else
            local contributionId = node.contributionId
            local label = info.text
            info.func = function()
                ContextMenu:InvokeContribution(contributionId, label)
            end
        end
        self:AddMenuInfo(info, level)
    end
end

function ContextMenu:RenderTreeChildren(node, level)
    if type(node) ~= "table" or type(node.children) ~= "table" then return end
    for _, child in ipairs(node.children) do
        self:AddTreeNode(child, level)
    end
end

function ContextMenu:InvokeContribution(contributionId, label)
    local active = self.activeMenu
    if not active or not active.entry then
        self:Print("Action unavailable: the menu context expired.")
        return false, "NO_ACTIVE_MENU_CONTEXT"
    end
    if not self.api or type(self.api.InvokeContextAction) ~= "function" then
        self:Print("Action unavailable: Core is not ready.")
        return false, "API_UNAVAILABLE"
    end

    local contextData = active.contextData or self:BuildContextData(active.entry)
    if type(HideDropDownMenu) == "function" then HideDropDownMenu(1) end

    local callOk, ok, result, detail = pcall(
        self.api.InvokeContextAction,
        self.api,
        contributionId,
        contextData
    )
    if not callOk then
        self:Print(tostring(label or "Action") .. " failed: " .. tostring(ok))
        return false, tostring(ok)
    end
    if ok ~= true then
        self:Print(tostring(label or "Action") .. " unavailable: " .. tostring(result or detail or "UNKNOWN"))
        return false, result or detail or "CONTEXT_ACTION_FAILED"
    end

    -- A returned transaction id means dispatch was accepted by Core, not that the
    -- gameplay mutation is authoritatively confirmed. Terminal state remains Core-owned.
    return true, result, detail
end

function ContextMenu:ClearPrimaryFromMenu()
    if not self.api or type(self.api.ClearSelection) ~= "function" then
        self:Print("Could not clear Selection: Core API unavailable.")
        return false, "API_UNAVAILABLE"
    end
    local before = self:GetPrimarySnapshot()
    if (before.count or 0) < 1 then
        self:Print("Selection is already empty.")
        return true
    end
    local callOk, ok, reason = pcall(self.api.ClearSelection, self.api, "PRIMARY")
    if not callOk then
        self:Print("Could not clear Selection: " .. tostring(ok))
        return false, tostring(ok)
    end
    if ok == false then
        self:Print("Could not clear Selection: " .. tostring(reason or "UNKNOWN"))
        return false, reason
    end
    if type(HideDropDownMenu) == "function" then HideDropDownMenu(1) end
    self:Print("Selection cleared.")
    return true
end


function ContextMenu:GetStrategyRecipients(entry)
    if not entry or not entry.context then return {}, "NO_CONTEXT" end
    local kind = entry.context.contextKind
    if self:IsExplicitBotContext(kind) then
        local name = self:GetContextBotName(entry.context)
        if not name or name == "" then return {}, "BOT_REQUIRED" end
        return { name }, nil, "EXPLICIT_BOT"
    elseif kind == "WORLD_EMPTY" then
        local names = {}
        for _, name in ipairs((entry.primary and entry.primary.names) or {}) do
            names[#names + 1] = name
        end
        if #names == 0 then return {}, "NO_TARGETS" end
        return names, nil, "PRIMARY_SNAPSHOT"
    end
    return {}, "CONTEXT_NOT_SELECTION_CONTROL"
end

function ContextMenu:GetStrategyMutationAvailability(entry, changes, stateScope)
    if not self.api or type(self.api.GetActionAvailability) ~= "function" then
        return false, "API_UNAVAILABLE", {}
    end
    local names, recipientErr = self:GetStrategyRecipients(entry)
    if #names == 0 then return false, recipientErr or "NO_TARGETS", {} end
    stateScope = stateScope == "C" and "C" or "N"

    local perBot = {}
    for _, name in ipairs(names) do
        local args = { scope = "BOT", stateScope = stateScope, changes = changes }
        local ok, availability = pcall(self.api.GetActionAvailability, self.api, "STRATEGY.MUTATE", name, args)
        if not ok or type(availability) ~= "table" then
            perBot[#perBot + 1] = { bot = name, enabled = false, reason = ok and "INVALID_AVAILABILITY" or tostring(availability) }
            return false, tostring(name) .. ": " .. tostring(perBot[#perBot].reason), perBot
        end
        perBot[#perBot + 1] = { bot = name, enabled = availability.enabled == true, reason = availability.reason }
        if availability.enabled ~= true then
            return false, tostring(name) .. ": " .. tostring(availability.reason or "UNAVAILABLE"), perBot
        end
    end
    return true, nil, perBot
end

function ContextMenu:ExecuteStrategyMutationFromMenu(changes, label, stateScope, keepOpen)
    local active = self.activeMenu
    if not active or not active.entry then
        self:Print(tostring(label or "Action") .. " unavailable: the menu context expired.")
        return false, "NO_ACTIVE_MENU_CONTEXT"
    end
    if not self.api then return false, "API_UNAVAILABLE" end

    local entry = active.entry
    stateScope = stateScope == "C" and "C" or "N"
    local enabled, reason = self:GetStrategyMutationAvailability(entry, changes, stateScope)
    if not enabled then
        self:Print(tostring(label or "Strategy") .. " unavailable: " .. tostring(reason or "UNKNOWN"))
        return false, reason
    end

    local names, recipientErr, recipientKind = self:GetStrategyRecipients(entry)
    if #names == 0 then return false, recipientErr or "NO_TARGETS" end
    local args = { scope = "BOT", stateScope = stateScope, changes = changes }

    if not keepOpen and type(HideDropDownMenu) == "function" then HideDropDownMenu(1) end

    local function callback(tx)
        if keepOpen and type(tx) == "table" and tx.state == "CONFIRMED" then
            ContextMenu:Schedule(0.05, function() ContextMenu:RefreshVisibleStrategyButtons() end)
        elseif keepOpen and type(tx) == "table" and (tx.state == "FAILED" or tx.state == "CANCELLED") then
            ContextMenu:Print(tostring(label or "Strategy") .. " failed: " .. tostring(tx.error or (tx.result and tx.result.reason) or tx.state))
        end
    end

    if recipientKind == "EXPLICIT_BOT" then
        if type(self.api.Execute) ~= "function" then return false, "EXECUTE_UNAVAILABLE" end
        local callOk, txId, err = pcall(self.api.Execute, self.api, MODULE, "STRATEGY.MUTATE", names[1], args, callback)
        if not callOk then
            self:Print(tostring(label or "Action") .. " failed: " .. tostring(txId))
            return false, tostring(txId)
        end
        if not txId then
            self:Print(tostring(label or "Action") .. " unavailable: " .. tostring(err or "UNKNOWN"))
            return false, err
        end
        return true, txId
    end

    if type(self.api.ExecuteSet) ~= "function" then return false, "EXECUTE_SET_UNAVAILABLE" end
    local frozenNames = {}
    for _, name in ipairs(names) do frozenNames[#frozenNames + 1] = name end
    local callOk, results = pcall(self.api.ExecuteSet, self.api, MODULE, "STRATEGY.MUTATE", frozenNames, args, callback)
    if not callOk then
        self:Print(tostring(label or "Action") .. " failed: " .. tostring(results))
        return false, tostring(results)
    end
    if type(results) ~= "table" then
        self:Print(tostring(label or "Action") .. " failed: invalid Core result.")
        return false, "INVALID_EXECUTE_SET_RESULT"
    end
    local failed = 0
    for _, result in ipairs(results) do if not result.transactionId then failed = failed + 1 end end
    if failed > 0 then self:Print(tostring(label or "Strategy") .. " could not be sent to " .. tostring(failed) .. " bot(s).") end
    return failed == 0, results
end

function ContextMenu:AddSelectionStrategyControls(entry, level)
    if type(UIDropDownMenu_CreateInfo) ~= "function" then return end
    local kind = entry and entry.context and entry.context.contextKind or nil
    if not self:IsExplicitBotContext(kind) and kind ~= "WORLD_EMPTY" then return end

    local followEnabled, followReason = self:GetStrategyMutationAvailability(entry, "+follow,-stay", "N")
    local stayEnabled, stayReason = self:GetStrategyMutationAvailability(entry, "+stay,-follow", "N")

    local follow = UIDropDownMenu_CreateInfo()
    follow.text = "Follow"
    follow.notCheckable = 1
    if not followEnabled then
        follow.disabled = 1
        follow.tooltipWhileDisabled = 1
        follow.tooltipOnButton = 1
        follow.tooltipTitle = "Follow"
        follow.tooltipText = tostring(followReason or "Unavailable")
    else
        follow.func = function() ContextMenu:ExecuteStrategyMutationFromMenu("+follow,-stay", "Follow", "N", false) end
    end
    self:AddMenuInfo(follow, level or 1)

    local stay = UIDropDownMenu_CreateInfo()
    stay.text = "Stay"
    stay.notCheckable = 1
    if not stayEnabled then
        stay.disabled = 1
        stay.tooltipWhileDisabled = 1
        stay.tooltipOnButton = 1
        stay.tooltipTitle = "Stay"
        stay.tooltipText = tostring(stayReason or "Unavailable")
    else
        stay.func = function() ContextMenu:ExecuteStrategyMutationFromMenu("+stay,-follow", "Stay", "N", false) end
    end
    self:AddMenuInfo(stay, level or 1)
end


local function lowerSet(list)
    local out = {}
    for _, value in ipairs(type(list) == "table" and list or {}) do
        out[string.lower(tostring(value or ""))] = true
    end
    return out
end

function ContextMenu:GetExplicitStrategyBot(entry)
    if not entry or not entry.context or not self:IsExplicitBotContext(entry.context.contextKind) then return nil end
    local name = self:GetContextBotName(entry.context)
    if not name then return nil end
    local bot = self.api and type(self.api.ResolveBot) == "function" and self.api:ResolveBot(name) or entry.context.bot
    return bot, name
end

function ContextMenu:GetBotStrategyProfile(entry)
    local bot, name = self:GetExplicitStrategyBot(entry)
    if not bot or not name then return nil, "BOT_REQUIRED" end
    local class = string.upper(string.gsub(tostring(bot.class or bot.className or (entry.context.unit and entry.context.unit.classFile) or ""), "[^A-Za-z]", ""))
    local classLabel = (entry.context.unit and entry.context.unit.classLocal) or bot.className or bot.class or class
    local state, meta = nil, nil
    if self.api and type(self.api.Get) == "function" then state, meta = self.api:Get("BOT.STATE", name) end
    local role = self.api and type(self.api.GetBotRole) == "function" and self.api:GetBotRole(name) or nil
    local spec = self.api and type(self.api.GetBotSpec) == "function" and self.api:GetBotSpec(name) or nil
    local range = self.api and type(self.api.GetBotRange) == "function" and select(1, self.api:GetBotRange(name)) or nil
    return {
        bot = bot, name = name, class = class, classLabel = classLabel,
        state = type(state) == "table" and state or {}, meta = meta,
        combat = lowerSet(state and state.combatStrategies),
        normal = lowerSet(state and state.normalStrategies),
        role = role and role.primary or "UNKNOWN",
        spec = spec and spec.primary or "UNKNOWN",
        specState = spec and spec.state or "UNKNOWN",
        range = range,
    }
end

function ContextMenu:BeginStrategyInterest(entry)
    local bot, name = self:GetExplicitStrategyBot(entry)
    if not bot or not name or not self.api or type(self.api.Acquire) ~= "function" then
        self:ReleaseStrategyInterest()
        return
    end
    if self.strategyInterestBot == name then return end
    self:ReleaseStrategyInterest()
    local ok = pcall(self.api.Acquire, self.api, MODULE, "BOT.STATE", name, { refreshNow = true })
    if ok then
        self.strategyInterestBot = name
        if self.timerFrame then self.timerFrame:Show() end
    end
end

function ContextMenu:ReleaseStrategyInterest()
    local name = self.strategyInterestBot
    self.strategyInterestBot = nil
    if name and self.api and type(self.api.Release) == "function" then
        pcall(self.api.Release, self.api, MODULE, "BOT.STATE", name)
    end
end

function ContextMenu:IsClassStrategyApplicable(item, profile)
    if not item or not profile then return false end
    if item.spec and profile.spec ~= item.spec then return false end
    if item.specs and not item.specs[profile.spec] then return false end
    if item.druidRole and profile.role ~= item.druidRole then
        -- Feral can be ambiguous until its active bear/cat strategy is known. In
        -- that case show both valid Feral role modes rather than guessing.
        if not (profile.class == "DRUID" and profile.spec == "Feral" and profile.role == "UNKNOWN") then return false end
    end
    return true
end

function ContextMenu:BuildCombatStrategyList(profile)
    local out = {}
    for _, item in ipairs(CO_COMMON) do out[#out + 1] = item end
    for _, item in ipairs(CO_BY_ROLE[profile.role] or {}) do out[#out + 1] = item end
    if profile.role == "DPS" and profile.range == "MELEE" then out[#out + 1] = { key = "behind", label = "Behind" } end
    local ccAllowed = CC_STRATEGY_CLASSES[profile.class] == true
    if profile.class == "PALADIN" and profile.spec == "Retribution" then ccAllowed = true end
    if ccAllowed then out[#out + 1] = { key = "cc", label = "CC", tooltip = "Use crowd-control behavior against the bot's assigned CC RTI target." } end
    return out
end

function ContextMenu:GetClassStrategyList(profile)
    local out = {}
    for _, item in ipairs(CLASS_STRATEGIES[profile.class] or {}) do
        if self:IsClassStrategyApplicable(item, profile) then out[#out + 1] = item end
    end
    return out
end

function ContextMenu:IsStrategyActive(profile, stateScope, key)
    if not profile then return false end
    local set = stateScope == "C" and profile.combat or profile.normal
    return set[string.lower(tostring(key or ""))] == true
end

function ContextMenu:StrategyDisplayText(label, active)
    if active then return STRATEGY_GREEN .. tostring(label) .. STRATEGY_RESET end
    return tostring(label)
end

function ContextMenu:AddStrategyToggle(entry, level, profile, item, stateScope)
    if type(UIDropDownMenu_CreateInfo) ~= "function" then return end
    stateScope = stateScope == "C" and "C" or "N"
    local active = self:IsStrategyActive(profile, stateScope, item.key)
    local change = (active and "-" or "+") .. item.key
    local enabled, reason = self:GetStrategyMutationAvailability(entry, change, stateScope)
    local info = UIDropDownMenu_CreateInfo()
    info.text = self:StrategyDisplayText(item.label or item.key, active)
    info.notCheckable = 1
    info.keepShownOnClick = 1
    info.value = { mbcmStrategyToggle = true, key = item.key, label = item.label or item.key, stateScope = stateScope }
    if item.tooltip then
        info.tooltipTitle = item.label or item.key
        info.tooltipText = item.tooltip
        info.tooltipOnButton = 1
    end
    if not enabled then
        info.disabled = 1
        info.tooltipWhileDisabled = 1
        info.tooltipOnButton = 1
        info.tooltipTitle = item.label or item.key
        info.tooltipText = tostring(reason or item.tooltip or "Unavailable")
    else
        local key, label, scope = item.key, item.label or item.key, stateScope
        info.func = function()
            local currentProfile = ContextMenu:GetBotStrategyProfile(ContextMenu.activeMenu and ContextMenu.activeMenu.entry)
            local nowActive = currentProfile and ContextMenu:IsStrategyActive(currentProfile, scope, key) or active
            local nextChange = (nowActive and "-" or "+") .. key
            ContextMenu:ExecuteStrategyMutationFromMenu(nextChange, label, scope, true)
        end
    end
    self:AddMenuInfo(info, level)
end

function ContextMenu:AddStrategiesRoot(entry, level)
    if not entry or not entry.context or not self:IsExplicitBotContext(entry.context.contextKind) then return end
    if type(UIDropDownMenu_CreateInfo) ~= "function" then return end
    local info = UIDropDownMenu_CreateInfo()
    info.text = "Strategies"
    info.notCheckable = 1
    info.hasArrow = 1
    info.value = { mbcmStrategies = "ROOT" }
    self:AddMenuInfo(info, level or 1)
end

function ContextMenu:RenderStrategiesMenu(entry, mode, level)
    local profile = self:GetBotStrategyProfile(entry)
    if not profile then return end

    if mode == "ROOT" then
        local nc = UIDropDownMenu_CreateInfo()
        nc.text, nc.notCheckable, nc.hasArrow = "NC", 1, 1
        nc.value = { mbcmStrategies = "NC" }
        self:AddMenuInfo(nc, level)

        local co = UIDropDownMenu_CreateInfo()
        co.text, co.notCheckable, co.hasArrow = "CO", 1, 1
        co.value = { mbcmStrategies = "CO" }
        self:AddMenuInfo(co, level)

        local classList = self:GetClassStrategyList(profile)
        if #classList > 0 then
            local classInfo = UIDropDownMenu_CreateInfo()
            classInfo.text, classInfo.notCheckable, classInfo.hasArrow = tostring(profile.classLabel or profile.class), 1, 1
            classInfo.value = { mbcmStrategies = "CLASS" }
            self:AddMenuInfo(classInfo, level)
        end

        local rti = UIDropDownMenu_CreateInfo()
        rti.text, rti.notCheckable, rti.hasArrow = "RTI", 1, 1
        rti.value = { mbcmStrategies = "RTI" }
        self:AddMenuInfo(rti, level)

        local ccrti = UIDropDownMenu_CreateInfo()
        ccrti.text, ccrti.notCheckable, ccrti.hasArrow = "CC RTI", 1, 1
        ccrti.value = { mbcmStrategies = "CCRTI" }
        self:AddMenuInfo(ccrti, level)
        return
    end

    if mode == "NC" then
        for _, item in ipairs(NC_STRATEGIES) do self:AddStrategyToggle(entry, level, profile, item, "N") end
        return
    elseif mode == "CO" then
        for _, item in ipairs(self:BuildCombatStrategyList(profile)) do self:AddStrategyToggle(entry, level, profile, item, "C") end
        return
    elseif mode == "CLASS" then
        for _, item in ipairs(self:GetClassStrategyList(profile)) do self:AddStrategyToggle(entry, level, profile, item, item.scope or "C") end
        return
    elseif mode == "RTI" or mode == "CCRTI" then
        local purpose = mode == "CCRTI" and "CC" or "PRIORITY"
        local assignment = self.api and type(self.api.GetRTIAssignment) == "function" and self.api:GetRTIAssignment(profile.name, purpose) or nil
        local activeIcon = type(assignment) == "table" and assignment.icon or nil
        local icons = self.api and type(self.api.GetRTIIcons) == "function" and self.api:GetRTIIcons() or {}
        for _, icon in ipairs(type(icons) == "table" and icons or {}) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = self:StrategyDisplayText(icon.label or icon.key, activeIcon == icon.key)
            info.notCheckable = 1
            info.keepShownOnClick = 1
            info.icon = icon.texture
            info.value = { mbcmRTIAssignment = purpose, icon = icon.key, label = icon.label or icon.key }
            local botName, iconKey, label = profile.name, icon.key, icon.label or icon.key
            local availability = self.api and type(self.api.GetActionAvailability) == "function" and self.api:GetActionAvailability(purpose == "CC" and "RTI.ASSIGN_CC" or "RTI.ASSIGN_PRIORITY", botName, { icon = iconKey }) or nil
            if type(availability) == "table" and availability.enabled ~= true then
                info.disabled = 1
                info.tooltipWhileDisabled = 1
                info.tooltipOnButton = 1
                info.tooltipTitle = label
                info.tooltipText = tostring(availability.reason or "Unavailable")
            else
                info.func = function() ContextMenu:AssignRTIFromMenu(botName, purpose, iconKey, label) end
            end
            self:AddMenuInfo(info, level)
        end
    end
end

function ContextMenu:AssignRTIFromMenu(botName, purpose, icon, label)
    if not self.api or type(self.api.AssignRTI) ~= "function" then return false, "API_UNAVAILABLE" end
    local ok, txId, err = pcall(self.api.AssignRTI, self.api, MODULE, botName, purpose, icon, function(tx)
        if type(tx) == "table" and tx.state == "CONFIRMED" then
            ContextMenu:Schedule(0.05, function() ContextMenu:RefreshVisibleStrategyButtons() end)
        elseif type(tx) == "table" and (tx.state == "FAILED" or tx.state == "CANCELLED") then
            ContextMenu:Print(tostring(label or "RTI") .. " assignment failed: " .. tostring(tx.error or tx.state))
        end
    end)
    if not ok then self:Print(tostring(label or "RTI") .. " assignment failed: " .. tostring(txId)); return false, tostring(txId) end
    if not txId then self:Print(tostring(label or "RTI") .. " assignment unavailable: " .. tostring(err or "UNKNOWN")); return false, err end
    return true, txId
end

function ContextMenu:RefreshVisibleStrategyButtons()
    local active = self.activeMenu
    local entry = active and active.entry
    local profile = entry and self:GetBotStrategyProfile(entry) or nil
    if not profile then return end
    for level = 1, 4 do
        local list = _G["DropDownList" .. tostring(level)]
        if list and type(list.IsShown) == "function" and list:IsShown() then
            local count = tonumber(list.numButtons) or 0
            for index = 1, count do
                local button = _G[list:GetName() .. "Button" .. tostring(index)]
                local value = button and button.value
                local text = button and _G[button:GetName() .. "NormalText"]
                if type(value) == "table" and value.mbcmStrategyToggle and text and type(text.SetText) == "function" then
                    local activeState = self:IsStrategyActive(profile, value.stateScope, value.key)
                    text:SetText(self:StrategyDisplayText(value.label or value.key, activeState))
                elseif type(value) == "table" and value.mbcmRTIAssignment and text and type(text.SetText) == "function" then
                    local assignment = self.api and type(self.api.GetRTIAssignment) == "function" and self.api:GetRTIAssignment(profile.name, value.mbcmRTIAssignment) or nil
                    text:SetText(self:StrategyDisplayText(value.label or value.icon, type(assignment) == "table" and assignment.icon == value.icon))
                end
            end
        end
    end
end



function ContextMenu:GetRTSCRecipients(entry)
    if not entry or not entry.context then return {}, "NO_CONTEXT" end
    local kind = entry.context.contextKind
    if self:IsExplicitBotContext(kind) then
        local name = self:GetContextBotName(entry.context)
        if not name or name == "" then return {}, "BOT_REQUIRED" end
        return { name }, nil, "EXPLICIT_BOT"
    elseif self:IsWorldSelectionContext(kind) then
        local names = {}
        for _, name in ipairs((entry.primary and entry.primary.names) or {}) do
            names[#names + 1] = name
        end
        if #names == 0 then return {}, "NO_TARGETS" end
        return names, nil, "PRIMARY_SNAPSHOT"
    end
    return {}, "CONTEXT_NOT_RTSC_CONTROL"
end

function ContextMenu:GetRTSCGoAvailability(entry, slot)
    if not self.api or type(self.api.GetActionAvailability) ~= "function" then
        return false, "API_UNAVAILABLE", {}
    end
    slot = tonumber(slot) or 0
    if slot < 1 or slot > 9 then return false, "INVALID_RTSC_SLOT", {} end

    local names, recipientErr = self:GetRTSCRecipients(entry)
    if #names == 0 then return false, recipientErr or "NO_TARGETS", {} end

    local frozenNames = {}
    for _, name in ipairs(names) do frozenNames[#frozenNames + 1] = name end
    local ok, availability = pcall(self.api.GetActionAvailability, self.api, "RTSC.GO", frozenNames, { slot = slot })
    if not ok or type(availability) ~= "table" then
        return false, ok and "INVALID_AVAILABILITY" or tostring(availability), frozenNames
    end
    return availability.enabled == true, availability.reason, frozenNames
end

function ContextMenu:ExecuteRTSCGoFromMenu(slot)
    local active = self.activeMenu
    if not active or not active.entry then
        self:Print("Move unavailable: the menu context expired.")
        return false, "NO_ACTIVE_MENU_CONTEXT"
    end
    if not self.api or type(self.api.GoRTSCLocation) ~= "function" then
        self:Print("Move unavailable: Core is not ready.")
        return false, "API_UNAVAILABLE"
    end
    if not self.rtscKnownSlots[tonumber(slot) or 0] then
        self:Print("Location " .. tostring(slot) .. " is not known this session.")
        return false, "RTSC_SLOT_NOT_SESSION_KNOWN"
    end

    local enabled, reason, frozenNames = self:GetRTSCGoAvailability(active.entry, slot)
    if not enabled then
        self:Print("Location " .. tostring(slot) .. " unavailable: " .. tostring(reason or "UNKNOWN"))
        return false, reason
    end

    if type(HideDropDownMenu) == "function" then HideDropDownMenu(1) end

    local callOk, txId, err = pcall(
        self.api.GoRTSCLocation,
        self.api,
        MODULE,
        frozenNames,
        slot,
        function() end
    )
    if not callOk then
        self:Print("Move to Location " .. tostring(slot) .. " failed: " .. tostring(txId))
        return false, tostring(txId)
    end
    if not txId then
        self:Print("Move to Location " .. tostring(slot) .. " unavailable: " .. tostring(err or "UNKNOWN"))
        return false, err
    end

    return true, txId
end

function ContextMenu:HasAEDMSpell()
    if type(GetNumSpellTabs) ~= "function" or type(GetSpellTabInfo) ~= "function" or type(GetSpellName) ~= "function" then
        return false, "SPELLBOOK_API_UNAVAILABLE"
    end
    local bookType = BOOKTYPE_SPELL or "spell"
    local tabs = GetNumSpellTabs() or 0
    for tab = 1, tabs do
        local _, _, offset, numSpells = GetSpellTabInfo(tab)
        offset = tonumber(offset) or 0
        numSpells = tonumber(numSpells) or 0
        for index = offset + 1, offset + numSpells do
            local name = GetSpellName(index, bookType)
            if type(name) == "string" and string.lower(name) == "aedm" then
                return true
            end
        end
    end
    return false
end

function ContextMenu:GetRTSCEnableAvailability()
    if not self.api then return false, "API_UNAVAILABLE" end
    if type(self.api.EnableRTSC) ~= "function" then return false, "CORE_1_1_RTSC_ENABLE_UNAVAILABLE" end
    if type(self.api.GetActionAvailability) ~= "function" then return true end

    local ok, availability = pcall(self.api.GetActionAvailability, self.api, "RTSC.ENABLE", "all", {})
    if not ok then return false, tostring(availability) end
    if type(availability) ~= "table" then return false, "INVALID_AVAILABILITY" end
    return availability.enabled == true, availability.reason
end

function ContextMenu:EnsureRTSCEnabledForMenu()
    local hasAEDM = self:HasAEDMSpell()
    if hasAEDM then
        self.rtscEnableObserved = true
        self.rtscEnableRequest = nil
        self:RefreshRTSCSecureOverlays()
        return true, "AEDM_PRESENT"
    end

    local available, reason = self:GetRTSCEnableAvailability()
    if not available then return false, reason end

    local now = GetTime and GetTime() or 0
    if self.rtscEnableRequest and (now - (self.rtscEnableRequest.requestedAt or 0)) < 5.0 then
        return true, "ENABLE_PENDING"
    end

    local callOk, txId, err = pcall(self.api.EnableRTSC, self.api, MODULE, function(tx)
        if type(tx) == "table" and (tx.state == "FAILED" or tx.state == "CANCELLED") then
            ContextMenu.rtscEnableRequest = nil
            ContextMenu:Print("RTSC could not be enabled for placement.")
        end
    end)
    if not callOk then return false, tostring(txId) end
    if not txId then return false, err or "RTSC_ENABLE_REFUSED" end

    self.rtscEnableRequest = { txId = txId, requestedAt = now }
    if self.timerFrame then self.timerFrame:Show() end
    return true, "ENABLE_REQUESTED"
end

function ContextMenu:GetRTSCSetAvailability(slot)
    slot = tonumber(slot) or 0
    if slot < 1 or slot > 9 then return false, "INVALID_RTSC_SLOT" end
    if InCombatLockdown and InCombatLockdown() then return false, "COMBAT_LOCKDOWN" end
    if not self.api then return false, "API_UNAVAILABLE" end
    if type(self.api.GetActionAvailability) ~= "function" or type(self.api.SaveRTSCLocation) ~= "function" then
        return false, "RTSC_SAVE_API_UNAVAILABLE"
    end
    if type(self.api.EnableRTSC) ~= "function" then return false, "CORE_1_1_RTSC_ENABLE_UNAVAILABLE" end

    local ok, availability = pcall(self.api.GetActionAvailability, self.api, "RTSC.SAVE", "all", { slot = slot })
    if not ok or type(availability) ~= "table" then
        return false, ok and "INVALID_AVAILABILITY" or tostring(availability)
    end
    if availability.enabled ~= true then return false, availability.reason or "RTSC_SAVE_UNAVAILABLE" end

    local contract = type(self.api.GetRTSCPlacementContract) == "function" and self.api:GetRTSCPlacementContract() or nil
    if type(contract) ~= "table" or contract.secureType ~= "macro" or type(contract.macroText) ~= "string" or contract.macroText == "" then
        return false, "RTSC_PLACEMENT_CONTRACT_UNAVAILABLE"
    end
    return true
end

function ContextMenu:Schedule(delay, fn)
    if type(fn) ~= "function" then return end
    self.delayedTasks[#self.delayedTasks + 1] = {
        due = (GetTime and GetTime() or 0) + math.max(0, tonumber(delay) or 0),
        fn = fn,
    }
    if self.timerFrame then self.timerFrame:Show() end
end

function ContextMenu:HideRTSCSecureOverlays()
    for _, button in pairs(self.rtscSecureButtons or {}) do
        if button and button.Hide then button:Hide() end
    end
    self.rtscSecureRows = {}
end

function ContextMenu:CreateRTSCSecureButton(slot, row)
    slot = tonumber(slot) or 0
    if slot < 1 or slot > 9 then return nil, "INVALID_RTSC_SLOT" end
    if InCombatLockdown and InCombatLockdown() then return nil, "COMBAT_LOCKDOWN" end

    local button = self.rtscSecureButtons[slot]
    if not button then
        if type(CreateFrame) ~= "function" then return nil, "CREATE_FRAME_UNAVAILABLE" end
        button = CreateFrame("Button", MODULE .. "_RTSCSetSlot" .. tostring(slot), row, "SecureActionButtonTemplate")
        if type(button.RegisterForClicks) == "function" then button:RegisterForClicks("LeftButtonUp") end
        button:SetFrameStrata("FULLSCREEN_DIALOG")
        button:SetScript("OnEnter", function(selfButton)
            local sourceRow = selfButton.mbcmRow
            if sourceRow and sourceRow.LockHighlight then sourceRow:LockHighlight() end
            local list = sourceRow and sourceRow.GetParent and sourceRow:GetParent() or nil
            if list and type(UIDropDownMenu_StopCounting) == "function" then UIDropDownMenu_StopCounting(list) end
        end)
        button:SetScript("OnLeave", function(selfButton)
            local sourceRow = selfButton.mbcmRow
            if sourceRow and sourceRow.UnlockHighlight then sourceRow:UnlockHighlight() end
            local list = sourceRow and sourceRow.GetParent and sourceRow:GetParent() or nil
            if list and type(UIDropDownMenu_StartCounting) == "function" then UIDropDownMenu_StartCounting(list) end
            if list and ContextMenu:IsOwnMenuOpen() then list.showTimer = ContextMenu:GetHoverGracePeriod() end
        end)
        button:SetScript("PreClick", function(selfButton, mouseButton)
            selfButton.mbcmPrepared = false
            selfButton.mbcmPrepareReason = nil
            if mouseButton ~= "LeftButton" then return end
            local ok, reason = ContextMenu:PrepareRTSCSetSecureClick(selfButton.mbcmSlot)
            selfButton.mbcmPrepared = ok == true
            selfButton.mbcmPrepareReason = reason
        end)
        button:SetScript("PostClick", function(selfButton, mouseButton)
            if mouseButton ~= "LeftButton" then return end
            ContextMenu:FinishRTSCSetSecureClick(selfButton.mbcmSlot, selfButton.mbcmPrepared, selfButton.mbcmPrepareReason)
        end)
        button:Hide()
        self.rtscSecureButtons[slot] = button
    end

    if button:GetParent() ~= row and type(button.SetParent) == "function" then button:SetParent(row) end
    button:ClearAllPoints()
    button:SetAllPoints(row)
    button:SetFrameLevel((row:GetFrameLevel() or 0) + 20)
    button.mbcmRow = row
    button.mbcmSlot = slot
    return button
end

function ContextMenu:ConfigureRTSCSecureRow(level, index, slot, enabled)
    local row = _G["DropDownList" .. tostring(level) .. "Button" .. tostring(index)]
    if not row then return false, "DROPDOWN_ROW_UNAVAILABLE" end
    local button, err = self:CreateRTSCSecureButton(slot, row)
    if not button then return false, err end

    local contract = self.api and type(self.api.GetRTSCPlacementContract) == "function" and self.api:GetRTSCPlacementContract() or nil
    if type(contract) ~= "table" or contract.secureType ~= "macro" or type(contract.macroText) ~= "string" then
        button:Hide()
        return false, "RTSC_PLACEMENT_CONTRACT_UNAVAILABLE"
    end

    button:SetAttribute("type", contract.secureType)
    button:SetAttribute("macrotext", contract.macroText)
    button.mbcmEnabled = enabled == true
    self.rtscSecureRows[slot] = { button = button, row = row, level = level, index = index }

    if enabled and self:HasAEDMSpell() then button:Show() else button:Hide() end
    return true
end

function ContextMenu:RefreshRTSCSecureOverlays()
    local ready = self:HasAEDMSpell()
    for slot, rowInfo in pairs(self.rtscSecureRows or {}) do
        local button = rowInfo.button
        local row = rowInfo.row
        if button then
            local enabled = button.mbcmEnabled == true and ready and row and row.IsShown and row:IsShown()
            if enabled then button:Show() else button:Hide() end
        end
    end
end

function ContextMenu:ObserveRTSCEnable()
    local request = self.rtscEnableRequest
    if not request then return end
    local now = GetTime and GetTime() or 0
    if self:HasAEDMSpell() then
        self.rtscEnableObserved = true
        self.rtscEnableRequest = nil
        self:RefreshRTSCSecureOverlays()
    elseif (now - (request.requestedAt or now)) >= 5.0 then
        self:Print("RTSC could not be enabled for placement.")
        self.rtscEnableRequest = nil
    end
end

function ContextMenu:PrepareRTSCSetSecureClick(slot)
    slot = tonumber(slot) or 0
    local enabled, reason = self:GetRTSCSetAvailability(slot)
    if not enabled then
        self:Print("Location " .. tostring(slot) .. " unavailable: " .. tostring(reason or "UNKNOWN"))
        return false, reason
    end
    if not self:HasAEDMSpell() then
        self:Print("RTSC is preparing Location " .. tostring(slot) .. ".")
        return false, "AEDM_NOT_READY"
    end

    local callOk, txId, err = pcall(self.api.SaveRTSCLocation, self.api, MODULE, slot, function(tx)
    end)
    if not callOk then
        self:Print("Location " .. tostring(slot) .. " failed: " .. tostring(txId))
        return false, tostring(txId)
    end
    if not txId then
        self:Print("Location " .. tostring(slot) .. " unavailable: " .. tostring(err or "UNKNOWN"))
        return false, err
    end

    self.rtscPlacement = {
        slot = slot,
        saveTxId = txId,
        clickedAt = GetTime and GetTime() or 0,
        sawTargeting = false,
        status = "SECURE_CAST_PENDING",
    }
    if self.timerFrame then self.timerFrame:Show() end
    return true, txId
end

function ContextMenu:FinishRTSCSetSecureClick(slot, prepared, reason)
    if type(HideDropDownMenu) == "function" then HideDropDownMenu(1) end
    self:HideRTSCSecureOverlays()

    if not prepared then
        self.rtscPlacement = nil
        self:Print("Location " .. tostring(slot) .. " unavailable: " .. tostring(reason or "UNKNOWN"))
        return false
    end

    local placement = self.rtscPlacement
    if not placement or tonumber(placement.slot) ~= tonumber(slot) then return false end
    placement.clickedAt = GetTime and GetTime() or placement.clickedAt or 0
    placement.sawTargeting = type(SpellIsTargeting) == "function" and SpellIsTargeting() and true or false
    placement.status = "AWAITING_GROUND_CLICK"
    self:Print("Location " .. tostring(slot) .. ": click the ground.")
    return true
end

function ContextMenu:OnRTSCSetRowFallback(slot)
    if not self:HasAEDMSpell() then
        self:EnsureRTSCEnabledForMenu()
        self:Print("RTSC is not ready yet. Keep the menu open and try the location again.")
        return false
    end
    self:Print("Location " .. tostring(slot) .. " is not ready. Reopen Set Location and try again.")
    return false
end

function ContextMenu:ObserveRTSCPlacement()
    local placement = self.rtscPlacement
    if not placement then return end
    local now = GetTime and GetTime() or 0
    local targeting = type(SpellIsTargeting) == "function" and SpellIsTargeting() and true or false
    if targeting then placement.sawTargeting = true end

    if placement.sawTargeting and not targeting and (now - (placement.clickedAt or now)) >= 0.10 then
        self.rtscKnownSlots[placement.slot] = {
            setAt = now,
            confidence = "ESTIMATED",
        }
        self:Print("Location " .. tostring(placement.slot) .. " saved for this session.")
        self.rtscPlacement = nil
    elseif not placement.sawTargeting and (now - (placement.clickedAt or now)) >= 5.0 then
        self:Print("Location " .. tostring(placement.slot) .. " was not placed.")
        self.rtscPlacement = nil
    end
end

function ContextMenu:GetRTSCUnsaveAvailability(slot)
    slot = tonumber(slot) or 0
    if slot < 1 or slot > 9 then return false, "INVALID_RTSC_SLOT" end
    if not self.rtscKnownSlots[slot] then return false, "RTSC_SLOT_NOT_SESSION_KNOWN" end
    if not self.api or type(self.api.GetActionAvailability) ~= "function" or type(self.api.UnsaveRTSCLocation) ~= "function" then
        return false, "API_UNAVAILABLE"
    end
    local ok, availability = pcall(self.api.GetActionAvailability, self.api, "RTSC.UNSAVE", "all", { slot = slot })
    if not ok or type(availability) ~= "table" then return false, ok and "INVALID_AVAILABILITY" or tostring(availability) end
    return availability.enabled == true, availability.reason
end

function ContextMenu:ExecuteRTSCUnsaveFromMenu(slot)
    slot = tonumber(slot) or 0
    local enabled, reason = self:GetRTSCUnsaveAvailability(slot)
    if not enabled then
        self:Print("Location " .. tostring(slot) .. " could not be cleared: " .. tostring(reason or "UNKNOWN"))
        return false, reason
    end
    if type(HideDropDownMenu) == "function" then HideDropDownMenu(1) end

    local callOk, txId, err = pcall(self.api.UnsaveRTSCLocation, self.api, MODULE, slot, function(tx)
    end)
    if not callOk then
        self:Print("Location " .. tostring(slot) .. " could not be cleared: " .. tostring(txId))
        return false, tostring(txId)
    end
    if not txId then
        self:Print("Location " .. tostring(slot) .. " could not be cleared: " .. tostring(err or "UNKNOWN"))
        return false, err
    end
    -- RTSC chat actions are best-effort. Session knowledge is deliberately an estimate;
    -- once UNSAVE is accepted for dispatch, stop presenting the slot as known.
    self.rtscKnownSlots[slot] = nil
    self:Print("Location " .. tostring(slot) .. " cleared.")
    return true, txId
end

function ContextMenu:GetRTSCClearAllAvailability()
    local known = self:GetKnownRTSCSlots()
    if #known == 0 then return false, "NO_SESSION_KNOWN_RTSC_SLOTS", known end

    for _, slot in ipairs(known) do
        local enabled, reason = self:GetRTSCUnsaveAvailability(slot)
        if not enabled then
            return false, "LOCATION_" .. tostring(slot) .. ":" .. tostring(reason or "UNAVAILABLE"), known
        end
    end
    return true, nil, known
end

function ContextMenu:ExecuteRTSCClearAllFromMenu()
    local enabled, reason, known = self:GetRTSCClearAllAvailability()
    if not enabled then
        self:Print("RTSC locations could not be cleared: " .. tostring(reason or "UNKNOWN"))
        return false, reason
    end
    if type(HideDropDownMenu) == "function" then HideDropDownMenu(1) end

    local requested = 0
    local failed = {}
    for _, slot in ipairs(known) do
        local selectedSlot = slot
        local callOk, txId, err = pcall(self.api.UnsaveRTSCLocation, self.api, MODULE, selectedSlot, function(tx)
        end)
        if callOk and txId then
            -- Each Core UNSAVE is independent/best-effort. Once accepted for dispatch,
            -- remove that slot from the module's deliberately estimated session knowledge.
            self.rtscKnownSlots[selectedSlot] = nil
            requested = requested + 1
        else
            failed[#failed + 1] = tostring(selectedSlot) .. ":" .. tostring(callOk and (err or "REFUSED") or txId)
        end
    end

    if #failed > 0 then
        self:Print("Cleared " .. tostring(requested) .. "/" .. tostring(#known) .. " RTSC locations; failed: " .. table.concat(failed, ", "))
        return false, "PARTIAL_DISPATCH"
    end

    self:Print("All known RTSC locations cleared.")
    return true
end

function ContextMenu:GetKnownRTSCSlots()
    local slots = {}
    for slot = 1, 9 do
        if self.rtscKnownSlots[slot] then slots[#slots + 1] = slot end
    end
    return slots
end

function ContextMenu:ResetRTSCKnowledge(reason)
    self.rtscKnownSlots = {}
    self.rtscPlacement = nil
    self.rtscEnableRequest = nil
    self.rtscEnableObserved = false
    self:HideRTSCSecureOverlays()
end

function ContextMenu:AddRTSCRoot(entry, level)
    if type(UIDropDownMenu_CreateInfo) ~= "function" then return end
    local kind = entry and entry.context and entry.context.contextKind or nil
    if not self:IsExplicitBotContext(kind) and not self:IsWorldSelectionContext(kind) then return end

    local info = UIDropDownMenu_CreateInfo()
    info.text = "RTSC"
    info.notCheckable = 1
    info.hasArrow = 1
    info.value = { mbcmRTSC = "ROOT" }
    self:AddMenuInfo(info, level or 1)
end

function ContextMenu:RenderRTSCMenu(entry, mode, level)
    if type(UIDropDownMenu_CreateInfo) ~= "function" then return end

    -- Legacy UIDropDownMenu recycles DropDownListNButtonM frames between sibling
    -- submenus. SET uses secure child buttons layered over those rows for the
    -- /cast aedm hardware click, so they MUST be hidden before any RTSC submenu
    -- is rendered/reused. SET immediately rebuilds the overlays for its own rows.
    self:HideRTSCSecureOverlays()

    local known = self:GetKnownRTSCSlots()

    if mode == "ROOT" then
        -- Core 1.1 owns RTSC enable/bootstrap. Merely opening RTSC does not
        -- enable it; the semantic enable request starts when Set Location is
        -- actually hovered/opened.
        local enableOk, enableReason = self:GetRTSCEnableAvailability()
        if self:HasAEDMSpell() then enableOk, enableReason = true, "AEDM_PRESENT" end

        local move = UIDropDownMenu_CreateInfo()
        move.text = "Move To"
        move.notCheckable = 1
        move.hasArrow = 1
        move.value = { mbcmRTSC = "MOVE" }
        if #known == 0 then
            move.disabled = 1
            move.tooltipWhileDisabled = 1
            move.tooltipOnButton = 1
            move.tooltipTitle = "Move To"
            move.tooltipText = "No RTSC locations are known in this addon session."
        end
        self:AddMenuInfo(move, level)

        -- Set/Clear manage shared RTSC location state and are therefore exposed
        -- only from the world/PRIMARY context. BOT_FRAME RTSC is intentionally
        -- restricted to actions that target the clicked bot alone.
        local kind = entry and entry.context and entry.context.contextKind or nil
        if not self:IsExplicitBotContext(kind) then
            local set = UIDropDownMenu_CreateInfo()
            set.text = "Set Location"
            set.notCheckable = 1
            set.hasArrow = 1
            set.value = { mbcmRTSC = "SET" }
            if not enableOk and not self:HasAEDMSpell() then
                set.disabled = 1
                set.tooltipWhileDisabled = 1
                set.tooltipOnButton = 1
                set.tooltipTitle = "Set Location"
                set.tooltipText = tostring(enableReason or "RTSC Enable unavailable")
            end
            self:AddMenuInfo(set, level)

            local clear = UIDropDownMenu_CreateInfo()
            clear.text = "Clear Location"
            clear.notCheckable = 1
            clear.hasArrow = 1
            clear.value = { mbcmRTSC = "CLEAR" }
            if #known == 0 then
                clear.disabled = 1
                clear.tooltipWhileDisabled = 1
                clear.tooltipOnButton = 1
                clear.tooltipTitle = "Clear Location"
                clear.tooltipText = "No RTSC locations are known in this addon session."
            end
            self:AddMenuInfo(clear, level)
        end
        return
    end

    if mode == "MOVE" then
        for _, slot in ipairs(known) do
            local enabled, reason = self:GetRTSCGoAvailability(entry, slot)
            local info = UIDropDownMenu_CreateInfo()
            info.text = "Location " .. tostring(slot)
            info.notCheckable = 1
            if not enabled then
                info.disabled = 1
                info.tooltipWhileDisabled = 1
                info.tooltipOnButton = 1
                info.tooltipTitle = info.text
                info.tooltipText = tostring(reason or "Unavailable")
            else
                local selectedSlot = slot
                info.func = function() ContextMenu:ExecuteRTSCGoFromMenu(selectedSlot) end
            end
            self:AddMenuInfo(info, level)
        end
        return
    end

    if mode == "SET" then
        -- Refresh the semantic enable request on entry. Usually AEDM is already
        -- available because ROOT requested it while the user hovered into RTSC.
        self:EnsureRTSCEnabledForMenu()

        for slot = 1, 9 do
            local enabled, reason = self:GetRTSCSetAvailability(slot)
            local info = UIDropDownMenu_CreateInfo()
            info.text = "Location " .. tostring(slot)
            info.notCheckable = 1
            if self.rtscKnownSlots[slot] then info.text = info.text .. " (replace)" end
            if not enabled then
                info.disabled = 1
                info.tooltipWhileDisabled = 1
                info.tooltipOnButton = 1
                info.tooltipTitle = info.text
                info.tooltipText = tostring(reason or "Unavailable")
            else
                local selectedSlot = slot
                -- The secure overlay normally receives the click and performs
                -- `/cast aedm`. This ordinary row callback is only a race/failure
                -- fallback while Core is still granting AEDM.
                info.keepShownOnClick = 1
                info.func = function() ContextMenu:OnRTSCSetRowFallback(selectedSlot) end
            end
            self:AddMenuInfo(info, level)

            local list = _G["DropDownList" .. tostring(level)]
            local index = list and tonumber(list.numButtons) or nil
            if enabled and index then
                local overlayOk, overlayErr = self:ConfigureRTSCSecureRow(level, index, slot, true)
                if not overlayOk and overlayErr ~= "COMBAT_LOCKDOWN" then
                    self:Print("Location " .. tostring(slot) .. " unavailable: " .. tostring(overlayErr or "UNKNOWN"))
                end
            end
        end
        self:RefreshRTSCSecureOverlays()
        return
    end

    if mode == "CLEAR" then
        local clearAllEnabled, clearAllReason = self:GetRTSCClearAllAvailability()
        local clearAll = UIDropDownMenu_CreateInfo()
        clearAll.text = "Clear All"
        clearAll.notCheckable = 1
        if not clearAllEnabled then
            clearAll.disabled = 1
            clearAll.tooltipWhileDisabled = 1
            clearAll.tooltipOnButton = 1
            clearAll.tooltipTitle = "Clear All"
            clearAll.tooltipText = tostring(clearAllReason or "Unavailable")
        else
            clearAll.func = function() ContextMenu:ExecuteRTSCClearAllFromMenu() end
        end
        self:AddMenuInfo(clearAll, level)

        for _, slot in ipairs(known) do
            local enabled, reason = self:GetRTSCUnsaveAvailability(slot)
            local info = UIDropDownMenu_CreateInfo()
            info.text = "Location " .. tostring(slot)
            info.notCheckable = 1
            if not enabled then
                info.disabled = 1
                info.tooltipWhileDisabled = 1
                info.tooltipOnButton = 1
                info.tooltipTitle = info.text
                info.tooltipText = tostring(reason or "Unavailable")
            else
                local selectedSlot = slot
                info.func = function() ContextMenu:ExecuteRTSCUnsaveFromMenu(selectedSlot) end
            end
            self:AddMenuInfo(info, level)
        end
    end
end

function ContextMenu:InitializeMenu(_, level)
    level = level or 1
    -- Blizzard positions dropdown levels after their initializer returns. Reset the
    -- reused list frame to scale 1 here so its previous MBCM scale cannot distort
    -- the next anchor calculation; presentation reapplies our requested scale.
    self:ResetDropdownScaleForAnchor(level)
    self:Schedule(0, function()
        if ContextMenu:IsOwnMenuOpen() then ContextMenu:ApplyMenuPresentation(level) end
    end)
    local active = self.activeMenu
    if not active or not active.entry then return end

    if level > 1 then
        local value = UIDROPDOWNMENU_MENU_VALUE
        if type(value) == "table" and value.mbcmRTSC then
            self:RenderRTSCMenu(active.entry, value.mbcmRTSC, level)
        elseif type(value) == "table" and value.mbcmStrategies then
            self:RenderStrategiesMenu(active.entry, value.mbcmStrategies, level)
        elseif type(value) == "table" and type(value.mbcmTreeNode) == "table" then
            self:RenderTreeChildren(value.mbcmTreeNode, level)
        end
        return
    end

    local entry = active.entry
    local context = entry.context or {}
    local primary = entry.primary or self:GetPrimarySnapshot()

    if self:IsExplicitBotContext(context.contextKind) then
        local botName = self:GetContextBotName(context) or (context.unit and context.unit.name) or "<unknown>"
        self:AddDisabledLine(self:ColorizeBotName(context, botName), 1, true)
        self:AddSelectionStrategyControls(entry, 1)
        self:AddStrategiesRoot(entry, 1)
    elseif context.contextKind == "WORLD_EMPTY" then
        if (primary.count or 0) < 1 then return end
        self:AddDisabledLine("Selection", 1, true)
        self:AddSelectionStrategyControls(entry, 1)
    else
        return
    end

    if self:IsExplicitBotContext(context.contextKind) or self:IsWorldSelectionContext(context.contextKind) then
        self:AddRTSCRoot(entry, 1)
    end

    if self:IsWorldSelectionContext(context.contextKind) and (primary.count or 0) > 0 then
        if type(UIDropDownMenu_CreateInfo) == "function" then
            local clearInfo = UIDropDownMenu_CreateInfo()
            clearInfo.text = "Clear Selection"
            clearInfo.notCheckable = 1
            clearInfo.func = function()
                ContextMenu:ClearPrimaryFromMenu()
            end
            self:AddMenuInfo(clearInfo, 1)
        end
    end

    local trees = active.trees or {}
    for _, preview in ipairs(trees) do
        self:RenderTreeChildren(preview.tree, 1)
    end

    if type(UIDropDownMenu_CreateInfo) == "function" then
        local info = UIDropDownMenu_CreateInfo()
        info.text = "Close"
        info.notCheckable = 1
        info.func = function()
            if type(HideDropDownMenu) == "function" then HideDropDownMenu(1) end
        end
        self:AddMenuInfo(info, 1)
    end
end

function ContextMenu:GetMenuAnchorFrame()
    if self.menuAnchor then return self.menuAnchor end
    if type(CreateFrame) ~= "function" or not UIParent then return nil end
    local frame = CreateFrame("Frame", MODULE .. "_CursorAnchor", UIParent)
    frame:SetWidth(1)
    frame:SetHeight(1)
    frame:Hide()
    self.menuAnchor = frame
    return frame
end

function ContextMenu:PositionMenuAnchorAtCursor()
    local anchor = self:GetMenuAnchorFrame()
    if not anchor or type(GetCursorPosition) ~= "function" then return nil, "CURSOR_ANCHOR_UNAVAILABLE" end
    local x, y = GetCursorPosition()
    local scale = 1
    if UIParent and type(UIParent.GetEffectiveScale) == "function" then
        scale = tonumber(UIParent:GetEffectiveScale()) or 1
        if scale <= 0 then scale = 1 end
    end
    x, y = (tonumber(x) or 0) / scale, (tonumber(y) or 0) / scale
    anchor:ClearAllPoints()
    anchor:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x, y)
    anchor:Show()
    return anchor
end

function ContextMenu:ResetDropdownScaleForAnchor(level)
    local list = _G["DropDownList" .. tostring(tonumber(level) or 1)]
    if list and type(list.SetScale) == "function" then
        pcall(list.SetScale, list, 1)
    end
end

function ContextMenu:CreateMenuFrame()
    if self.menuFrame then return true end
    if type(CreateFrame) ~= "function" or type(UIDropDownMenu_Initialize) ~= "function" then
        return false, "DROPDOWN_API_UNAVAILABLE"
    end

    local frame = CreateFrame("Frame", MODULE .. "_Menu", UIParent, "UIDropDownMenuTemplate")
    frame.displayMode = "MENU"
    UIDropDownMenu_Initialize(frame, function(dropdown, level)
        ContextMenu:InitializeMenu(dropdown, level)
    end, "MENU")
    self.menuFrame = frame
    return true
end

function ContextMenu:OpenPreviewMenu(entry)
    if not entry or not entry.context then return false, "NO_CONTEXT" end
    self:HideRTSCSecureOverlays()
    local kind = entry.context.contextKind
    local eligible, eligibilityReason = self:IsMenuEligibleContext(kind)
    if not eligible then
        return false, eligibilityReason or "CONTEXT_NOT_MENU_ELIGIBLE"
    end
    if kind == "WORLD_EMPTY" and ((entry.primary and entry.primary.count) or 0) < 1 then
        if type(HideDropDownMenu) == "function" then HideDropDownMenu(1) end
        self.activeMenu = nil
        return false, "NO_SELECTION"
    end

    local ok, err = self:CreateMenuFrame()
    if not ok then return false, err end
    if type(ToggleDropDownMenu) ~= "function" then return false, "TOGGLE_DROPDOWN_UNAVAILABLE" end

    if self:IsExplicitBotContext(kind) then self:BeginStrategyInterest(entry) else self:ReleaseStrategyInterest() end

    self.activeMenu = {
        entry = entry,
        contextData = self:BuildContextData(entry),
        trees = self:GetPreviewTrees(entry),
        openedAt = GetTime and GetTime() or 0,
    }
    local anchor, anchorErr = self:PositionMenuAnchorAtCursor()
    if not anchor then return false, anchorErr end
    self:ResetDropdownScaleForAnchor(1)
    self.ownMenuOpening = true
    local callOk, callErr = pcall(ToggleDropDownMenu, 1, nil, self.menuFrame, anchor:GetName(), 0, 0)
    self.ownMenuOpening = false
    if not callOk then return false, tostring(callErr or "MENU_OPEN_FAILED") end
    self:RefreshVisibleMenuPresentation()
    self.menuOpenCount = self.menuOpenCount + 1
    return true
end

function ContextMenu:Record(entry)
    self.last = entry
    table.insert(self.history, 1, entry)
    while #self.history > self.maxHistory do table.remove(self.history) end
end

function ContextMenu:EvidenceText(entry)
    local evidence = {}
    if entry.worldDownSeen then evidence[#evidence + 1] = "worldDown" end
    if entry.worldUpSeen then evidence[#evidence + 1] = "worldUp" end
    if entry.frameDownSeen then evidence[#evidence + 1] = "frameDown" end
    if entry.frameUpSeen then evidence[#evidence + 1] = "frameUp" end
    if entry.overrideSeen then evidence[#evidence + 1] = "override" end
    if entry.mouselookSeen then evidence[#evidence + 1] = "mouselook" end
    if entry.targetChanged then evidence[#evidence + 1] = "targetChanged" end
    if entry.dropdownLeak then evidence[#evidence + 1] = "dropdown" end
    if entry.interactionEvent then evidence[#evidence + 1] = entry.interactionEvent end
    if #evidence == 0 then return "none" end
    return join(evidence, "+")
end

function ContextMenu:PrintEntry(entry, phase)
    if not entry then return end
    local botText = entry.context.botResolved and (entry.context.bot.name or "resolved") or "none"

    self:Print(
        "#" .. tostring(entry.id) .. " " .. tostring(phase or "observe") ..
        " SHIFT+RMB" ..
        " surface=" .. tostring(entry.surface or "UNKNOWN") ..
        " context=" .. tostring(entry.context.contextKind) ..
        " focus=" .. tostring(entry.context.focusName) ..
        " unit=" .. self:DescribeUnit(entry.context.unit) ..
        " bot=" .. tostring(botText) ..
        " PRIMARY=" .. self:DescribePrimary(entry.primary) ..
        " evidence=" .. self:EvidenceText(entry) ..
        " suppress=" .. tostring(entry.suppression or "PENDING")
    )
end

function ContextMenu:IsPendingRecent(maxAge)
    if not self.pending or not self.pending.entry then return false end
    local now = GetTime and GetTime() or 0
    return now - (self.pending.entry.startedAt or 0) <= (maxAge or 1.5)
end

function ContextMenu:StartGesture(source, explicitFrame, surface)
    if self.pending then
        self:FinalizePending("REPLACED_BY_NEW_GESTURE")
    end

    self.sequence = self.sequence + 1
    local entry = {
        id = self.sequence,
        startedAt = GetTime and GetTime() or 0,
        source = source,
        surface = surface or "UNKNOWN",
        modifier = "SHIFT",
        context = self:ResolveContext(source, explicitFrame),
        primary = nil,
        targetBefore = nil,
        targetAfter = nil,
        worldDownSeen = false,
        worldUpSeen = false,
        frameDownSeen = false,
        frameUpSeen = false,
        overrideSeen = source == "OVERRIDE_BINDING",
        mouselookSeen = false,
        targetChanged = false,
        dropdownLeak = false,
        interactionEvent = nil,
        suppression = "PENDING",
        inCombat = InCombatLockdown and InCombatLockdown() and true or false,
        finalized = false,
    }

    local entryKind = entry.context and entry.context.contextKind
    if self:NeedsPrimarySnapshot(entryKind) then
        entry.primary = self:GetPrimarySnapshot()
    else
        entry.primary = { count = 0, names = {}, ready = false, skipped = true }
    end
    if self:IsMenuEligibleContext(entryKind) then
        entry.targetBefore = self:GetTargetSnapshot()
    end

    if surface == "WORLD" and source == "WORLD_HOOK" then entry.worldDownSeen = true end
    if surface == "UNITFRAME" and source == "UNITFRAME_HOOK" then entry.frameDownSeen = true end

    self.pending = { entry = entry, elapsed = 0 }
    self:Record(entry)
    if self.timerFrame then self.timerFrame:Show() end
    return entry
end

function ContextMenu:RefreshPendingContext(entry, source, explicitFrame)
    if not entry then return end
    local current = self:ResolveContext(source, explicitFrame)
    if current and current.contextKind ~= "UI_OTHER" then
        entry.context = current
    end
    if self:NeedsPrimarySnapshot(entry.context and entry.context.contextKind) then
        entry.primary = self:GetPrimarySnapshot()
    else
        entry.primary = { count = 0, names = {}, ready = false, skipped = true }
    end
end

function ContextMenu:HandleWorldMouseDown()
    if not self.enabled or not self.captureEnabled then return end
    if self:GetModifierLabel() ~= "SHIFT" then return end

    local entry = self:StartGesture("WORLD_HOOK", WorldFrame, "WORLD")
    entry.worldDownSeen = true
end

function ContextMenu:HandleWorldMouseUp()
    if not self.enabled or not self.captureEnabled then return end
    if not self.pending or not self.pending.entry then return end
    local entry = self.pending.entry
    if entry.surface ~= "WORLD" then return end
    entry.worldUpSeen = true
    entry.releasedAt = GetTime and GetTime() or 0
    self:RefreshPendingContext(entry, "WORLD_HOOK", WorldFrame)
end

function ContextMenu:HandleUnitFrameMouseDown(frame)
    if not self.enabled or not self.captureEnabled then return end
    if self:GetModifierLabel() ~= "SHIFT" then return end

    local entry = self:StartGesture("UNITFRAME_HOOK", frame, "UNITFRAME")
    entry.frameDownSeen = true
end

function ContextMenu:HandleUnitFrameMouseUp(frame)
    if not self.enabled or not self.captureEnabled then return end
    if not self.pending or not self.pending.entry then return end
    local entry = self.pending.entry
    if entry.surface ~= "UNITFRAME" then return end
    entry.frameUpSeen = true
    entry.releasedAt = GetTime and GetTime() or 0
    self:RefreshPendingContext(entry, "UNITFRAME_HOOK", frame)
    if entry.context and entry.context.contextKind == "BOT_FRAME" then
        local ok, err = self:OpenPreviewMenu(entry)
        if not ok and err ~= "NO_SELECTION" and err ~= "CONTEXT_NOT_MENU_ELIGIBLE" and err ~= "WORLD_BOT_DISABLED" and err ~= "WORLD_BOT_COMBAT_DISABLED" then
            self:Print("Menu could not open: " .. tostring(err))
        end
    end
end

function ContextMenu:HandleOverride()
    if not self.enabled or not self.captureEnabled then return end

    local entry
    if self:IsPendingRecent(5.0) and not self.pending.entry.overrideSeen then
        entry = self.pending.entry
        entry.overrideSeen = true
        entry.overrideAt = GetTime and GetTime() or 0
        self:RefreshPendingContext(entry, "OVERRIDE_BINDING")
        if entry.surface == "WORLD" and entry.context and self:IsMenuEligibleContext(entry.context.contextKind) then
            local ok, err = self:OpenPreviewMenu(entry)
            if not ok and err ~= "NO_SELECTION" and err ~= "CONTEXT_NOT_MENU_ELIGIBLE" and err ~= "WORLD_BOT_DISABLED" and err ~= "WORLD_BOT_COMBAT_DISABLED" then
                self:Print("Menu could not open: " .. tostring(err))
            end
        end
    else
        entry = self:StartGesture("OVERRIDE_BINDING", nil, "BINDING_ONLY")
        entry.overrideSeen = true
        entry.overrideAt = GetTime and GetTime() or 0
    end
end

function ContextMenu:ObserveMouselook()
    if not self.pending or not self.pending.entry then return end
    if type(IsMouselooking) == "function" and IsMouselooking() then
        self.pending.entry.mouselookSeen = true
    end
end

function ContextMenu:ObserveTargetChange()
    if not self.pending or not self.pending.entry then return end
    local entry = self.pending.entry
    if not entry.targetBefore then return end
    local after = self:GetTargetSnapshot()
    entry.targetAfter = after

    local beforeGuid = entry.targetBefore and entry.targetBefore.guid or nil
    local afterGuid = after and after.guid or nil
    if beforeGuid ~= afterGuid then
        entry.targetChanged = true
    end
end

function ContextMenu:ObserveInteraction(event)
    if not self.pending or not self.pending.entry then return end
    self.pending.entry.interactionEvent = event
end

function ContextMenu:ObserveDropdown()
    if self.ownMenuOpening then return end
    if not self.pending or not self.pending.entry then return end
    self.pending.entry.dropdownLeak = true
end

function ContextMenu:FinalizePending(forcedReason)
    local pending = self.pending
    if not pending or not pending.entry then return end

    local entry = pending.entry
    if entry.finalized then
        self.pending = nil
        return
    end

    if entry.dropdownLeak then
        entry.suppression = "NO_DEFAULT_UNIT_MENU_OPENED"
    elseif entry.interactionEvent then
        entry.suppression = "NO_DEFAULT_NPC_INTERACTION_" .. tostring(entry.interactionEvent)
    elseif entry.mouselookSeen then
        entry.suppression = "NO_DEFAULT_MOUSELOOK_STARTED"
    elseif entry.targetChanged then
        entry.suppression = "NO_DEFAULT_TARGET_CHANGED"
    elseif entry.surface == "UNITFRAME" and entry.frameDownSeen and entry.frameUpSeen then
        entry.suppression = "YES_SECURE_SHIFT_NOOP_NO_DEFAULT_EFFECT"
    elseif not entry.overrideSeen then
        entry.suppression = "NO_OVERRIDE_NOT_CAPTURED"
    elseif forcedReason == "REPLACED_BY_NEW_GESTURE" then
        entry.suppression = "INCONCLUSIVE_REPLACED"
    else
        entry.suppression = "LIKELY_YES_NO_DEFAULT_EFFECT_OBSERVED"
    end

    entry.finalized = true
    entry.finalizedAt = GetTime and GetTime() or 0
    self.pending = nil
    if self.timerFrame then self.timerFrame:Hide() end
end

function ContextMenu:IsElvUIUnitFrame(frame)
    if not frame then return false end
    local name = safeCall(frame, "GetName")
    return type(name) == "string" and string.sub(name, 1, 6) == "ElvUF_"
end

function ContextMenu:ApplyUnitFrameSuppression(frame)
    if not self.captureEnabled then return false, "CAPTURE_DISABLED" end
    if not self:IsElvUIUnitFrame(frame) then return false, "NOT_ELVUI_UNITFRAME" end
    local existing = self.suppressedUnitFrames[frame]
    if existing then
        local current = safeCall(frame, "GetAttribute", "shift-type2")
        if current == "" then return true end
        if InCombatLockdown and InCombatLockdown() then
            self.unitFrameSuppressionError = "COMBAT_LOCKDOWN"
            return false, self.unitFrameSuppressionError
        end
        local ok, err = pcall(frame.SetAttribute, frame, "shift-type2", "")
        if ok then
            self.unitFrameSuppressionError = nil
            return true
        end
        self.unitFrameSuppressionError = tostring(err or "SET_ATTRIBUTE_FAILED")
        return false, self.unitFrameSuppressionError
    end
    if InCombatLockdown and InCombatLockdown() then
        self.unitFrameSuppressionError = "COMBAT_LOCKDOWN"
        return false, self.unitFrameSuppressionError
    end
    if type(frame.SetAttribute) ~= "function" or type(frame.GetAttribute) ~= "function" then
        self.unitFrameSuppressionError = "SECURE_ATTRIBUTES_UNAVAILABLE"
        return false, self.unitFrameSuppressionError
    end

    local original = safeCall(frame, "GetAttribute", "shift-type2")
    local record = {
        original = original,
        originalWasNil = original == nil,
    }

    -- WoW 3.3.5 SecureTemplates defines ATTRIBUTE_NOOP as the empty string.
    -- An explicit shift-type2 no-op prevents fallback to ElvUI's ordinary *type2="menu".
    local ok, err = pcall(frame.SetAttribute, frame, "shift-type2", "")
    if not ok then
        self.unitFrameSuppressionError = tostring(err or "SET_ATTRIBUTE_FAILED")
        return false, self.unitFrameSuppressionError
    end

    self.suppressedUnitFrames[frame] = record
    self.unitFrameSuppressionCount = self.unitFrameSuppressionCount + 1
    self.unitFrameSuppressionError = nil
    return true
end

function ContextMenu:RestoreUnitFrameSuppression()
    if InCombatLockdown and InCombatLockdown() then
        self.unitFrameSuppressionError = "COMBAT_LOCKDOWN"
        return false, self.unitFrameSuppressionError
    end

    local restored = 0
    for frame, record in pairs(self.suppressedUnitFrames) do
        if frame and type(frame.SetAttribute) == "function" then
            local value = nil
            if record and not record.originalWasNil then value = record.original end
            local ok = pcall(frame.SetAttribute, frame, "shift-type2", value)
            if ok then restored = restored + 1 end
        end
        self.suppressedUnitFrames[frame] = nil
    end
    self.unitFrameSuppressionCount = 0
    self.unitFrameSuppressionError = nil
    return true, nil, restored
end

function ContextMenu:HookUnitFrame(frame)
    if not frame then return false end
    if self.hookedUnitFrames[frame] then
        if self.captureEnabled then self:ApplyUnitFrameSuppression(frame) end
        return false
    end
    if type(frame.HookScript) ~= "function" then return false end

    local unit = nil
    if type(frame.unit) == "string" and frame.unit ~= "" then unit = frame.unit end
    if not unit and frame.GetAttribute then
        local value = safeCall(frame, "GetAttribute", "unit")
        if type(value) == "string" and value ~= "" then unit = value end
    end
    if not unit then return false end

    self.hookedUnitFrames[frame] = true
    self.hookedUnitFrameCount = self.hookedUnitFrameCount + 1
    if self.captureEnabled then self:ApplyUnitFrameSuppression(frame) end

    frame:HookScript("OnMouseDown", function(selfFrame, button)
        if button == "RightButton" and ContextMenu:GetModifierLabel() == "SHIFT" then
            ContextMenu:HandleUnitFrameMouseDown(selfFrame)
        end
    end)
    frame:HookScript("OnMouseUp", function(selfFrame, button)
        if button == "RightButton" then
            ContextMenu:HandleUnitFrameMouseUp(selfFrame)
        end
    end)
    return true
end

function ContextMenu:ScanUnitFrames()
    if type(EnumerateFrames) ~= "function" then
        self.lastScanCandidates = 0
        return 0, "ENUMERATE_FRAMES_UNAVAILABLE"
    end

    local frame = nil
    local candidates = 0
    local added = 0
    while true do
        frame = EnumerateFrames(frame)
        if not frame then break end

        local unit = nil
        if type(frame.unit) == "string" and frame.unit ~= "" then unit = frame.unit end
        if not unit and frame.GetAttribute then
            local value = safeCall(frame, "GetAttribute", "unit")
            if type(value) == "string" and value ~= "" then unit = value end
        end

        if unit then
            candidates = candidates + 1
            if self:HookUnitFrame(frame) then added = added + 1 end
        end
    end

    self.lastScanCandidates = candidates
    return added, nil, candidates
end

function ContextMenu:InstallPassiveHooks()
    if self.passiveHooksInstalled then return end
    self.passiveHooksInstalled = true

    if WorldFrame and WorldFrame.HookScript then
        WorldFrame:HookScript("OnMouseDown", function(_, button)
            if button == "RightButton" and ContextMenu:GetModifierLabel() == "SHIFT" then
                ContextMenu:HandleWorldMouseDown()
            end
        end)
        WorldFrame:HookScript("OnMouseUp", function(_, button)
            if button == "RightButton" then
                ContextMenu:HandleWorldMouseUp()
            end
        end)
    end

    if hooksecurefunc and type(ToggleDropDownMenu) == "function" then
        hooksecurefunc("ToggleDropDownMenu", function()
            ContextMenu:ObserveDropdown()
        end)
    end
end

function ContextMenu:CreateCaptureButton()
    if self.bindingOwner then return end

    self.bindingOwner = CreateFrame("Frame", MODULE .. "_BindingOwner", UIParent)

    local shiftButton = CreateFrame("Button", MODULE .. "_ShiftCapture", UIParent)
    shiftButton:SetWidth(1)
    shiftButton:SetHeight(1)
    shiftButton:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", -64, -64)
    shiftButton:SetAlpha(0)
    shiftButton:RegisterForClicks("RightButtonUp")
    shiftButton:SetScript("OnClick", function()
        ContextMenu:HandleOverride()
    end)
    shiftButton:Show()

    self.shiftButton = shiftButton
end

function ContextMenu:InstallBinding()
    self:CreateCaptureButton()

    if not self.captureEnabled then
        self.bindingInstalled = false
        self.bindingError = "CAPTURE_DISABLED"
        return false, self.bindingError
    end

    if InCombatLockdown and InCombatLockdown() then
        self.bindingInstalled = false
        self.bindingError = "COMBAT_LOCKDOWN"
        return false, self.bindingError
    end

    if type(SetOverrideBindingClick) ~= "function" then
        self.bindingInstalled = false
        self.bindingError = "SET_OVERRIDE_BINDING_CLICK_UNAVAILABLE"
        return false, self.bindingError
    end

    if type(ClearOverrideBindings) == "function" then
        pcall(ClearOverrideBindings, self.bindingOwner)
    end

    local ok, err = pcall(
        SetOverrideBindingClick,
        self.bindingOwner,
        true,
        "SHIFT-BUTTON2",
        self.shiftButton:GetName(),
        "RightButton"
    )

    if ok then
        self.bindingInstalled = true
        self.bindingError = nil
        return true
    end

    self.bindingInstalled = false
    self.bindingError = tostring(err or "BINDING_INSTALL_FAILED")
    return false, self.bindingError
end

function ContextMenu:SetCaptureEnabled(enabled)
    enabled = enabled == true
    if InCombatLockdown and InCombatLockdown() then
        return false, "COMBAT_LOCKDOWN"
    end

    self.captureEnabled = enabled
    if not enabled then
        if self.bindingOwner and type(ClearOverrideBindings) == "function" then
            pcall(ClearOverrideBindings, self.bindingOwner)
        end
        self.bindingInstalled = false
        self.bindingError = "CAPTURE_DISABLED"
        self:RestoreUnitFrameSuppression()
    self:ReleaseStrategyInterest()
        return true
    end

    local bindingOk, bindingErr = self:InstallBinding()
    self:ScanUnitFrames()
    return bindingOk, bindingErr
end

function ContextMenu:PrintStatus()
    local primary = self:GetPrimarySnapshot()
    local coreVersion = self.api and self.api:GetCoreVersion() or "unavailable"
    local apiVersion = self.api and self.api:GetVersion() or "unavailable"
    local coreReady = self.api and self.api:IsReady() or false
    local bridgeReady = self.api and self.api:IsBridgeReady() or false
    local registryReady = self.api and self.api:IsBotRegistryReady() or false

    self:Print("version=" .. VERSION .. " Core=" .. tostring(coreVersion) .. " API=" .. tostring(apiVersion))
    self:Print(
        "ready core=" .. boolText(coreReady) ..
        " bridge=" .. boolText(bridgeReady) ..
        " registry=" .. boolText(registryReady) ..
        " combat=" .. boolText(InCombatLockdown and InCombatLockdown())
    )
    self:Print(
        "capture=" .. boolText(self.captureEnabled) ..
        " shiftBinding=" .. boolText(self.bindingInstalled) ..
        " ctrlBinding=off" ..
        " bindingError=" .. tostring(self.bindingError or "none")
    )
    self:Print("PRIMARY=" .. self:DescribePrimary(primary))
    self:Print("menu settings worldScale=" .. tostring(self:GetWorldMenuScale()) .. " unitFrameScale=" .. tostring(self:GetUnitFrameMenuScale()) .. " worldBotMode=" .. tostring(self:GetWorldBotMode()) .. " text=" .. tostring(self:GetMenuTextSize()) .. " grace=" .. tostring(self:GetHoverGracePeriod()) .. "s transparency=" .. tostring(math.floor(clamp(self:GetSettings().backgroundTransparency, 0, 100) + 0.5)) .. "%")
    self:Print("unitFrameHooks=" .. tostring(self.hookedUnitFrameCount) .. " lastScanCandidates=" .. tostring(self.lastScanCandidates))
    self:Print("unitFrameShiftSuppress=" .. tostring(self.unitFrameSuppressionCount) .. " suppressError=" .. tostring(self.unitFrameSuppressionError or "none"))
    self:Print("menus=" .. tostring(self.menuOpenCount) .. " contextActions=enabled selectionActions=follow/stay")
end

function ContextMenu:PrintLast()
    local entry = self.last
    if not entry then
        self:Print("No Shift+Right-click has been observed yet.")
        return
    end

    self:PrintEntry(entry, "last")
    self:Print(
        "details id=" .. tostring(entry.id) ..
        " combat=" .. boolText(entry.inCombat) ..
        " worldDown=" .. boolText(entry.worldDownSeen) ..
        " worldUp=" .. boolText(entry.worldUpSeen) ..
        " frameDown=" .. boolText(entry.frameDownSeen) ..
        " frameUp=" .. boolText(entry.frameUpSeen) ..
        " override=" .. boolText(entry.overrideSeen) ..
        " mouselook=" .. boolText(entry.mouselookSeen) ..
        " targetChanged=" .. boolText(entry.targetChanged) ..
        " dropdown=" .. boolText(entry.dropdownLeak) ..
        " interaction=" .. tostring(entry.interactionEvent or "none")
    )
end

function ContextMenu:PrintHistory()
    if #self.history == 0 then
        self:Print("History is empty.")
        return
    end

    local limit = math.min(#self.history, 10)
    self:Print("Last " .. tostring(limit) .. " Shift+RMB gestures:")
    for index = 1, limit do
        local entry = self.history[index]
        self:Print(
            "#" .. tostring(entry.id) ..
            " " .. tostring(entry.context.contextKind) ..
            " unit=" .. tostring(entry.context.unit and entry.context.unit.name or "none") ..
            " evidence=" .. self:EvidenceText(entry) ..
            " suppress=" .. tostring(entry.suppression)
        )
    end
end

function ContextMenu:ProbeFocus()
    local context = self:ResolveContext("FOCUS_PROBE")
    local primary = self:GetPrimarySnapshot()
    self:Print(
        "focus context=" .. tostring(context.contextKind) ..
        " focus=" .. tostring(context.focusName) ..
        " unit=" .. self:DescribeUnit(context.unit) ..
        " bot=" .. tostring(context.botResolved and context.bot.name or "none") ..
        " PRIMARY=" .. self:DescribePrimary(primary)
    )
end

function ContextMenu:HandleSlash(input)
    input = trim(input)
    local command, rest = string.match(input, "^(%S+)%s*(.-)$")
    command = string.lower(command or "status")
    rest = string.lower(trim(rest))

    if command == "status" or command == "" then
        self:PrintStatus()
    elseif command == "last" then
        self:PrintLast()
    elseif command == "history" then
        self:PrintHistory()
    elseif command == "focus" then
        self:ProbeFocus()
    elseif command == "menu" then
        if self.last then
            local ok, err = self:OpenPreviewMenu(self.last)
            self:Print("preview menu=" .. boolText(ok) .. " reason=" .. tostring(err or "none"))
        else
            self:Print("No observed context is available for preview.")
        end
    elseif command == "scan" then
        local added, err, candidates = self:ScanUnitFrames()
        self:Print("unit-frame scan added=" .. tostring(added or 0) .. " candidates=" .. tostring(candidates or 0) .. " totalHooks=" .. tostring(self.hookedUnitFrameCount) .. " reason=" .. tostring(err or "none"))
    elseif command == "bindings" then
        local ok, err = self:InstallBinding()
        self:Print("SHIFT binding reinstall=" .. boolText(ok) .. " reason=" .. tostring(err or "none"))
    elseif command == "capture" then
        if rest == "on" then
            local ok, err = self:SetCaptureEnabled(true)
            self:Print("capture on=" .. boolText(ok) .. " reason=" .. tostring(err or "none"))
        elseif rest == "off" then
            local ok, err = self:SetCaptureEnabled(false)
            self:Print("capture off=" .. boolText(ok) .. " reason=" .. tostring(err or "none"))
        else
            self:Print("Usage: /mbcm capture on|off")
        end
    elseif command == "rtsc" then
        local slots = self:GetKnownRTSCSlots()
        self:Print("RTSC session-known slots=" .. (#slots > 0 and join(slots) or "none") ..
            " AEDM=" .. boolText(self:HasAEDMSpell()) ..
            " enablePending=" .. boolText(self.rtscEnableRequest ~= nil) ..
            " placement=" .. tostring(self.rtscPlacement and self.rtscPlacement.slot or "none"))
    elseif command == "clear" then
        self.history = {}
        self.last = nil
        self:Print("Diagnostic history cleared.")
    else
        self:Print("Commands: status, last, history, focus, menu, scan, bindings, capture on|off, rtsc, clear")
    end
end

function ContextMenu:Initialize()
    if self.initialized then return true end

    -- ElvUI 6.09 creates E.data/E.db inside E:Initialize(). Runtime binding is
    -- valid only from LibElvUIPlugin's post-initialize lifecycle (or a genuine
    -- late/manual load where those objects already exist).
    if not self.E or type(self.E.data) ~= "table" or type(self.E.db) ~= "table" then
        return false, "ELVUI_NOT_READY"
    end

    local db, dbReason = self:InitializeSettings()
    if not db then return false, dbReason end
    self:RegisterElvUIProfileCallbacks()
    if type(self.RegisterOptionsPlugin) == "function" then
        local optionsOK, optionsReason = self:RegisterOptionsPlugin()
        if not optionsOK and optionsReason then
            self:Print("ElvUI options registration unavailable: " .. tostring(optionsReason))
        end
    end

    self.initialized = true
    return self:Enable()
end

function ContextMenu:Enable()
    if self.enabled then return true end
    if not self.initialized or not (self.E and type(self.E.data) == "table" and type(self.E.db) == "table") then
        return false, "ELVUI_NOT_INITIALIZED"
    end

    self.core = _G.ElvUI_Multibot_Core
    if not self.core or type(self.core.GetAPI) ~= "function" then
        self:Print("Core global/API unavailable; module not enabled.")
        return false
    end

    local api, err = self.core:GetAPI(1)
    if not api then
        self:Print("Core API v1 unavailable: " .. tostring(err))
        return false
    end

    self.api = api
    local ok, registerErr = self.api:RegisterModule(MODULE, {
        version = VERSION,
        description = "Shift-right-click Core context frontend with customizable menu presentation and selection-safe controls",
    })
    if ok == false then
        self:Print("Core module registration failed: " .. tostring(registerErr))
        return false
    end

    self.enabled = true
    if type(self.api.Subscribe) == "function" then
        local token = self.api:Subscribe(MODULE, "MB_SESSION_CHANGED", function()
            ContextMenu:ResetRTSCKnowledge("Core session changed")
        end)
        if token then self.subscriptions[#self.subscriptions + 1] = token end
        local dataToken = self.api:Subscribe(MODULE, "MB_DATA_CHANGED", function(_, domainId, targetKey)
            if domainId == "BOT.STATE" and ContextMenu.strategyInterestBot then
                local bot = ContextMenu.api and ContextMenu.api:ResolveBot(ContextMenu.strategyInterestBot)
                if bot and bot.key == targetKey then ContextMenu:Schedule(0, function() ContextMenu:RefreshVisibleStrategyButtons() end) end
            end
        end)
        if dataToken then self.subscriptions[#self.subscriptions + 1] = dataToken end
        local rtiToken = self.api:Subscribe(MODULE, "MB_RTI_ASSIGNMENTS_CHANGED", function()
            if ContextMenu.strategyInterestBot then ContextMenu:Schedule(0, function() ContextMenu:RefreshVisibleStrategyButtons() end) end
        end)
        if rtiToken then self.subscriptions[#self.subscriptions + 1] = rtiToken end
    end
    self:InstallPassiveHooks()
    local scanAdded, scanErr, scanCandidates = self:ScanUnitFrames()
    local bindingOk, bindingErr = self:InstallBinding()

    if not bindingOk then
        self:Print("Shift+Right-click binding could not be installed: " .. tostring(bindingErr or "unknown error"))
    elseif scanErr then
        self:Print("UnitFrame setup warning: " .. tostring(scanErr))
    end
    return true
end

function ContextMenu:Disable()
    if not self.enabled then return true end
    if InCombatLockdown and InCombatLockdown() then
        return false, "COMBAT_LOCKDOWN"
    end

    if self.bindingOwner and type(ClearOverrideBindings) == "function" then
        pcall(ClearOverrideBindings, self.bindingOwner)
    end
    self.bindingInstalled = false
    self:RestoreUnitFrameSuppression()

    self:ResetRTSCKnowledge()
    self.delayedTasks = {}
    self.subscriptions = {}
    if self.api and type(self.api.UnregisterModule) == "function" then
        self.api:UnregisterModule(MODULE)
    end

    self.enabled = false
    return true
end

local timerFrame = CreateFrame("Frame", MODULE .. "_Timer", UIParent)
timerFrame:Hide()
timerFrame:SetScript("OnUpdate", function(self, elapsed)
    local now = GetTime and GetTime() or 0

    if #ContextMenu.delayedTasks > 0 then
        local remaining = {}
        for _, task in ipairs(ContextMenu.delayedTasks) do
            if task.due <= now then
                local ok, err = pcall(task.fn)
                if not ok then ContextMenu:Print("Internal task failed: " .. tostring(err)) end
            else
                remaining[#remaining + 1] = task
            end
        end
        ContextMenu.delayedTasks = remaining
    end

    ContextMenu:ObserveRTSCEnable()
    ContextMenu:ObserveRTSCPlacement()

    if ContextMenu.strategyInterestBot and not ContextMenu:IsOwnMenuOpen() and not ContextMenu.ownMenuOpening then
        ContextMenu:ReleaseStrategyInterest()
    end

    if ContextMenu.pending and ContextMenu.pending.entry then
        ContextMenu:ObserveMouselook()
        ContextMenu.pending.elapsed = (ContextMenu.pending.elapsed or 0) + (elapsed or 0)

        local entry = ContextMenu.pending.entry
        local age = now - (entry.startedAt or 0)
        local sinceRelease = entry.releasedAt and (now - entry.releasedAt) or nil

        if entry.overrideSeen then
            local anchor = entry.releasedAt or entry.overrideAt
            if anchor and (now - anchor) >= 0.15 then
                ContextMenu:FinalizePending()
            end
        elseif sinceRelease and sinceRelease >= 0.35 then
            ContextMenu:FinalizePending()
        elseif age >= 5.0 then
            ContextMenu:FinalizePending("GESTURE_TIMEOUT")
        end
    end

    if (not ContextMenu.pending or not ContextMenu.pending.entry) and #ContextMenu.delayedTasks == 0 and not ContextMenu.rtscPlacement and not ContextMenu.rtscEnableRequest and not ContextMenu.strategyInterestBot then
        self:Hide()
    end
end)
ContextMenu.timerFrame = timerFrame

local eventFrame = CreateFrame("Frame", MODULE .. "_Events", UIParent)
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PARTY_MEMBERS_CHANGED")
eventFrame:RegisterEvent("RAID_ROSTER_UPDATE")
for eventName in pairs(INTERACTION_EVENTS) do
    eventFrame:RegisterEvent(eventName)
end

eventFrame:SetScript("OnEvent", function(_, event, arg1)
    if not ContextMenu.initialized then return end

    if event == "PLAYER_REGEN_DISABLED" and ContextMenu.enabled then
        -- The OUT_OF_COMBAT policy is based on WoW's own combat state. If a
        -- WORLD_BOT menu was already open when combat starts, close it so the
        -- policy cannot be bypassed by leaving the dropdown open.
        local activeKind = ContextMenu.activeMenu and ContextMenu.activeMenu.entry and ContextMenu.activeMenu.entry.context and ContextMenu.activeMenu.entry.context.contextKind
        if activeKind == "WORLD_BOT" and ContextMenu:GetWorldBotMode() == "OUT_OF_COMBAT" then
            if type(HideDropDownMenu) == "function" then HideDropDownMenu(1) end
            ContextMenu.activeMenu = nil
            ContextMenu:HideRTSCSecureOverlays()
            ContextMenu:ReleaseStrategyInterest()
        end
    elseif event == "PLAYER_REGEN_ENABLED" and ContextMenu.enabled and ContextMenu.captureEnabled then
        if not ContextMenu.bindingInstalled then ContextMenu:InstallBinding() end
        ContextMenu:ScanUnitFrames()
    elseif (event == "PLAYER_ENTERING_WORLD" or event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE") and ContextMenu.enabled then
        ContextMenu:ScanUnitFrames()
    elseif event == "PLAYER_TARGET_CHANGED" then
        ContextMenu:ObserveTargetChange()
    elseif INTERACTION_EVENTS[event] then
        ContextMenu:ObserveInteraction(event)
    end
end)
ContextMenu.eventFrame = eventFrame

SLASH_ELVUIMULTIBOTCONTEXTMENU1 = "/mbcm"
SLASH_ELVUIMULTIBOTCONTEXTMENU2 = "/multibotcontext"
SlashCmdList.ELVUIMULTIBOTCONTEXTMENU = function(input)
    ContextMenu:HandleSlash(input)
end

