local ADDON = ...

local ElvUI = _G.ElvUI
if not ElvUI then return end

local E, L, V, P, G = unpack(ElvUI)
if not E then return end

local MODULE = "ElvUI_Multibot_CommandPanel"
local VERSION = "0.1.0-alpha10.6"
local SCRATCH_SLOT = 9
local SCRATCH_ARM_SETTLE = 0.40
local MAGIC_DPS_SELECTION = "Magic DPS"
local PHYSICAL_DPS_SELECTION = "Physical DPS"
local MAX_FRONT_SHORTCUTS = 8
local MAX_PRESETS = 16

local DEFAULT_SETTINGS = {
    enabled = true,
    width = 500,
    height = 320,
    scale = 1.0,
    alpha = 0.96,
    buttonHeight = 28,
    frontButtonHeight = 42,
    spacing = 5,
    fontSize = 12,
    autoReturn = false,
    showStatus = true,
    frontShortcuts = {},
    presets = {},
    activePreset = nil,
    presetDirty = false,
    uiRevision = 9,
    rtiPanelOpen = false,
}

-- ElvUI 6.09 creates its AceDB profile from P during E:Initialize(). Register
-- defaults while addon files load, but do not bind profile-backed runtime state
-- or create UI until LibElvUIPlugin's post-initialize lifecycle fires.
if type(P) == "table" then
    P.multibotCommandPanel = type(P.multibotCommandPanel) == "table" and P.multibotCommandPanel or {}
    local defaults = P.multibotCommandPanel
    for key, value in pairs(DEFAULT_SETTINGS) do
        if defaults[key] == nil then
            if type(value) == "table" then
                defaults[key] = {}
            else
                defaults[key] = value
            end
        end
    end
end

local CP = E:NewModule("MultibotCommandPanel", "AceEvent-3.0")
_G.ElvUI_Multibot_CommandPanel = CP

CP.MODULE = MODULE
CP.VERSION = VERSION
CP.SCRATCH_SLOT = SCRATCH_SLOT
CP.API = nil
CP.Core = nil
CP.frame = nil
CP.buttonPool = {}
CP.buttonCount = 0
CP.subscriptions = {}
CP.workflow = { mode = "front" }
CP.knownSlots = {}
CP.positionHistory = {}
CP.flipPair = nil
CP.rtscEnableRequest = nil
CP.placement = nil
CP.placementContract = nil
CP.secureReady = false
CP.secureSetupReason = "NOT_CONFIGURED"
CP.secureGridButtons = {}
CP.secureGridCovers = {}
CP.gotoStayBarrier = nil
CP.damageSelectionsReady = false
CP.frontSecureActions = {}
CP.presetDialog = nil
CP.deletePresetDialog = nil
CP.frontContextMenu = nil
CP.pendingStayMoves = {}
CP.rtiPanel = nil
CP.rtiPanelRecipient = { label = "All", spec = "all" }
CP.rtiPanelPurpose = "priority"
CP.footerNextOrder = "FOLLOW"
CP.lastScratchCleanupAt = 0
CP.scratchGeneration = 0
CP.scratchCleanup = nil
CP.scratchPrimed = false
CP.scratchPrimeDueAt = nil
CP.scratchPrimeReason = nil
CP.scratchArmReadyAt = nil
CP.statusText = "Initializing..."
CP.initialized = false
CP.db = nil
CP.profileCallbacksRegistered = false
CP.optionsPluginRegistered = false

local FORMATIONS = {
    "near", "melee", "line", "circle",
    "arrow", "queue", "chaos", "shield",
}

local FALLBACK_RTI = {
    "skull", "cross", "circle", "star",
    "square", "triangle", "diamond", "moon",
}

local RAID_ICON_BY_INDEX = {
    [1] = "star",
    [2] = "circle",
    [3] = "diamond",
    [4] = "triangle",
    [5] = "moon",
    [6] = "square",
    [7] = "cross",
    [8] = "skull",
}

local RAID_INDEX_BY_ICON = {
    star = 1, circle = 2, diamond = 3, triangle = 4,
    moon = 5, square = 6, cross = 7, skull = 8,
}

-- WoW 3.3.5a does not expose every sizing convenience available on newer
-- clients. Keep frame construction on the oldest-safe width/height surface.
local CreateHeaderButton

local function SetFrameSize(frame, width, height)
    frame:SetWidth(width)
    frame:SetHeight(height)
end

-- CommandPanel initializes from ElvUI's post-initialize plugin lifecycle. Use
-- the configured ElvUI font when available and retain a native fallback for
-- unusual late/manual-load cases.
local function GetUIFont()
    if E.media and E.media.normFont and E.media.normFont ~= "" then
        return E.media.normFont
    end

    if _G.GameFontNormal and _G.GameFontNormal.GetFont then
        local path = _G.GameFontNormal:GetFont()
        if path and path ~= "" then return path end
    end

    return "Fonts\\FRIZQT__.TTF"
end

local function SetUIFont(fontString, size)
    fontString:SetFont(GetUIFont(), size, "OUTLINE")
end

local function wipeTable(t)
    for k in pairs(t) do t[k] = nil end
end

local function shallowCopyArray(t)
    local out = {}
    if type(t) ~= "table" then return out end
    for i = 1, #t do out[i] = t[i] end
    return out
end

local function deepCopy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local out = {}
    seen[value] = out
    for k, v in pairs(value) do out[deepCopy(k, seen)] = deepCopy(v, seen) end
    return out
end

local function trim(value)
    value = tostring(value or "")
    value = string.gsub(value, "^%s+", "")
    value = string.gsub(value, "%s+$", "")
    return value
end

local function safeLower(v)
    return type(v) == "string" and string.lower(v) or ""
end

local function listContains(t, value)
    if type(t) ~= "table" then return false end
    for i = 1, #t do
        if t[i] == value then return true end
    end
    return false
end

function CP:InitializeSettings()
    if not E or type(E.data) ~= "table" or type(E.db) ~= "table" then
        return nil, "ELVUI_PROFILE_NOT_READY"
    end

    E.db.multibotCommandPanel = type(E.db.multibotCommandPanel) == "table" and E.db.multibotCommandPanel or {}
    local db = E.db.multibotCommandPanel

    -- These two values are mutable containers. AceDB defaults may be supplied
    -- through a metatable, so force profile-owned raw tables before mutation.
    local rawFront = rawget and rawget(db, "frontShortcuts") or nil
    local rawPresets = rawget and rawget(db, "presets") or nil
    if type(rawFront) ~= "table" then db.frontShortcuts = {} end
    if type(rawPresets) ~= "table" then db.presets = {} end

    if db.frontButtonHeight == nil then db.frontButtonHeight = 42 end
    if db.presetDirty == nil then db.presetDirty = false end
    if db.rtiPanelOpen == nil then db.rtiPanelOpen = false end
    if db.uiRevision == nil or db.uiRevision < 6 then
        -- Alpha6 is a deliberate UI redesign. Migrate only untouched Alpha5
        -- dimensions; preserve sizes the user had actually customized.
        if db.width == nil or db.width == 450 then db.width = 500 end
        if db.height == nil or db.height == 252 then db.height = 320 end
        if db.spacing == nil or db.spacing == 4 then db.spacing = 5 end
        db.uiRevision = 6
    end
    if db.uiRevision < 9 then db.uiRevision = 9 end

    db.frontShortcuts = self:NormalizeFrontShortcuts(db.frontShortcuts)
    for name, preset in pairs(db.presets) do
        if type(preset) == "table" and type(preset.shortcuts) == "table" then
            preset.shortcuts = self:NormalizeFrontShortcuts(preset.shortcuts)
        end
    end

    self.db = db
    return db
end

function CP:GetDB()
    if E and type(E.data) == "table" and type(E.db) == "table" then
        local current = E.db.multibotCommandPanel
        if type(current) ~= "table" or current ~= self.db then
            local db = self:InitializeSettings()
            if db then return db end
        end
    end
    return self.db or (type(P) == "table" and P.multibotCommandPanel) or DEFAULT_SETTINGS
end

function CP:OnElvUIProfileChanged()
    self.db = nil
    local db = self:InitializeSettings()
    if not db then return end
    if self.frame then
        self:ApplySettings()
        self:RefreshHeaderControls()
    end
end

function CP:RegisterElvUIProfileCallbacks()
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

function CP:SetStatus(text)
    self.statusText = tostring(text or "")
    if self.frame and self.frame.status then
        self.frame.status:SetText(self.statusText)
    end
end

function CP:Print(msg)
    if E and E.Print then
        E:Print("|cff1784d1CommandPanel:|r " .. tostring(msg))
    else
        print("CommandPanel: " .. tostring(msg))
    end
end

function CP:GetSelectionCount()
    if not self.API or not self.API.GetSelection then return 0 end
    local selected = self.API:GetSelection("PRIMARY")
    return type(selected) == "table" and #selected or 0
end

function CP:NormalizeResolved(candidate)
    if type(candidate) ~= "table" then return nil end

    if type(candidate.targets) == "table" then candidate = candidate.targets
    elseif type(candidate.bots) == "table" then candidate = candidate.bots
    elseif type(candidate.refs) == "table" then candidate = candidate.refs
    elseif type(candidate.names) == "table" then candidate = candidate.names
    end

    local out = {}
    if #candidate > 0 then
        for i = 1, #candidate do
            out[#out + 1] = candidate[i]
        end
    else
        for k, v in pairs(candidate) do
            if type(k) == "number" then
                out[#out + 1] = v
            elseif v == true then
                out[#out + 1] = k
            elseif type(v) == "string" or type(v) == "table" then
                out[#out + 1] = v
            end
        end
    end

    if #out == 0 then return nil end
    return out
end

function CP:FreezeTarget(targetSpec)
    if not self.API or not self.API.ResolveTargetSpec then return nil end
    local a, b = self.API:ResolveTargetSpec(targetSpec)
    local frozen = self:NormalizeResolved(a)
    if not frozen then frozen = self:NormalizeResolved(b) end
    return frozen
end

function CP:RefDisplay(ref)
    if type(ref) == "string" then return ref end
    if type(ref) == "table" then
        return tostring(ref.name or ref.key or ref.guid or ref.id or ref.ref or "bot")
    end
    return tostring(ref)
end

function CP:FrozenKey(frozen)
    if type(frozen) ~= "table" or #frozen == 0 then return nil end
    local names = {}
    for i = 1, #frozen do names[i] = self:RefDisplay(frozen[i]) end
    table.sort(names)
    return table.concat(names, "|")
end

function CP:FrozenCount(frozen)
    return type(frozen) == "table" and #frozen or 0
end

function CP:ResolveRecipient(def)
    local frozen = self:FreezeTarget(def.spec)
    return frozen, self:FrozenCount(frozen)
end

function CP:GetRecipientDefs(mode)
    local defs = {}
    local selectedCount = self:GetSelectionCount()

    if mode ~= "formation" and selectedCount > 0 then
        defs[#defs + 1] = {
            label = "Selected (" .. selectedCount .. ")",
            short = "Selected",
            spec = "selected",
            summonMode = "EXPLICIT",
            movementMode = "FROZEN",
        }
    end

    defs[#defs + 1] = {
        label = "All", short = "All", spec = "all",
        summonMode = "RAID", summonCommand = "do summon",
        movementMode = "SEMANTIC",
    }

    if mode == "formation" then
        for i = 1, 8 do
            defs[#defs + 1] = {
                label = "Group " .. i, short = "G" .. i, spec = "group:" .. i,
                summonMode = "RAID", summonCommand = "@group" .. i .. " do summon",
                movementMode = "SEMANTIC",
            }
        end
        return defs
    end

    defs[#defs + 1] = {
        label = "Tanks", short = "Tanks", spec = "tank",
        summonMode = "RAID", summonCommand = "@tank do summon",
        movementMode = "SEMANTIC",
    }
    defs[#defs + 1] = {
        label = "Healers", short = "Healers", spec = "healer",
        summonMode = "RAID", summonCommand = "@heal do summon",
        movementMode = "SEMANTIC",
    }
    defs[#defs + 1] = {
        label = "Melee", short = "Melee", spec = "melee",
        summonMode = "EXPLICIT",
        movementMode = "SEMANTIC",
    }
    defs[#defs + 1] = {
        label = "Ranged", short = "Ranged", spec = "ranged",
        summonMode = "RAID", summonCommand = "@ranged do summon",
        movementMode = "SEMANTIC",
    }
    defs[#defs + 1] = {
        label = "DPS", short = "DPS", spec = "dps",
        summonMode = "RAID", summonCommand = "@dps do summon",
        movementMode = "SEMANTIC",
    }
    defs[#defs + 1] = {
        label = "Melee DPS", short = "Melee DPS", spec = "meleedps",
        summonMode = "RAID", summonCommand = "@meleedps do summon",
        movementMode = "SEMANTIC",
    }
    defs[#defs + 1] = {
        label = "Ranged DPS", short = "Ranged DPS", spec = "rangeddps",
        summonMode = "RAID", summonCommand = "@rangeddps do summon",
        movementMode = "SEMANTIC",
    }
    defs[#defs + 1] = {
        label = "Magic DPS", short = "Magic DPS", spec = "saved:" .. MAGIC_DPS_SELECTION,
        summonMode = "EXPLICIT",
        movementMode = "FROZEN",
    }
    defs[#defs + 1] = {
        label = "Physical DPS", short = "Physical DPS", spec = "saved:" .. PHYSICAL_DPS_SELECTION,
        summonMode = "EXPLICIT",
        movementMode = "FROZEN",
    }
    defs[#defs + 1] = { label = "Raid Groups...", short = "Groups", special = "groups" }
    return defs
end

function CP:GetGroupDefs()
    local defs = {}
    for i = 1, 8 do
        defs[#defs + 1] = {
            label = "Group " .. i, short = "G" .. i, spec = "group:" .. i,
            summonMode = "RAID", summonCommand = "@group" .. i .. " do summon",
            movementMode = "SEMANTIC",
        }
    end
    return defs
end

function CP:RefreshDamageSelections()
    if not self.API or not self.API.ResolveTargetSpec or not self.API.SaveSelection then return false end

    local dps = self:FreezeTarget("dps") or {}
    local magic, physical = {}, {}

    for i = 1, #dps do
        local bot = dps[i]
        local class = ""
        if type(bot) == "table" then
            class = string.upper(tostring(bot.class or bot.className or ""))
            class = string.gsub(class, "[^A-Z]", "")
        end

        local range = self.API.GetBotRange and self.API:GetBotRange(bot) or nil
        range = type(range) == "string" and string.upper(range) or ""

        if class == "HUNTER" or range == "MELEE" then
            physical[#physical + 1] = bot
        elseif range == "RANGED" then
            magic[#magic + 1] = bot
        end
    end

    local function maintain(name, refs)
        local existing = self.API.GetSavedSelection and self.API:GetSavedSelection(name) or nil
        if existing and existing.owner ~= MODULE then
            return true, "USER_OWNED"
        end
        local saved, err = self.API:SaveSelection(name, refs, { owner = MODULE })
        return saved ~= nil, err
    end

    local magicOk = maintain(MAGIC_DPS_SELECTION, magic)
    local physicalOk = maintain(PHYSICAL_DPS_SELECTION, physical)
    self.damageSelectionsReady = magicOk == true and physicalOk == true
    return self.damageSelectionsReady
end

function CP:RecipientForShortcut(recipient)
    local out = {
        recipientLabel = recipient.label,
        spec = recipient.spec,
        summonMode = recipient.summonMode,
        summonCommand = recipient.summonCommand,
        movementMode = recipient.movementMode,
    }
    if recipient.spec == "selected" and type(recipient.frozen) == "table" then
        out.frozen = {}
        for i = 1, #recipient.frozen do out.frozen[i] = self:RefDisplay(recipient.frozen[i]) end
    end
    return out
end

function CP:ResolveShortcutRecipient(shortcut)
    local frozen
    if type(shortcut.frozen) == "table" and #shortcut.frozen > 0 then
        frozen = self:FreezeTarget(shortcut.frozen)
    else
        frozen = self:FreezeTarget(shortcut.spec)
    end
    return {
        label = shortcut.recipientLabel or shortcut.label or shortcut.spec or "Bots",
        spec = shortcut.spec,
        frozen = frozen,
        summonMode = shortcut.summonMode,
        summonCommand = shortcut.summonCommand,
        movementMode = shortcut.movementMode,
    }
end

function CP:ShortcutLabel(shortcut)
    if type(shortcut) ~= "table" then return "Shortcut" end
    local who = shortcut.recipientLabel or "Bots"
    local kind = shortcut.kind
    if kind == "summon" then return "SUMMON " .. who end
    if kind == "order" then return who .. " " .. string.upper(tostring(shortcut.order or "ORDER")) end
    if kind == "goto" then return who .. " GO TO" end
    if kind == "move" then return who .. " -> L" .. tostring(shortcut.slot or "?") end
    if kind == "set_location" then return "SET LOCATION " .. tostring(shortcut.slot or "?") end
    if kind == "clear_location" then return "CLEAR LOCATION " .. tostring(shortcut.slot or "?") end
    if kind == "rti_assign" then return who .. " -> " .. string.upper(tostring(shortcut.icon or "RTI")) end
    if kind == "rti_run" then return who .. " " .. string.upper(tostring(shortcut.mode or "RTI")) .. " RTI" end
    if kind == "strategy" then return who .. " " .. tostring(shortcut.actionLabel or shortcut.label or "STRATEGY") end
    if kind == "combat" then return who .. " " .. tostring(shortcut.actionLabel or shortcut.command or "COMMAND") end
    if kind == "formation" then return who .. " " .. string.upper(tostring(shortcut.formation or "FORMATION")) end
    if kind == "flipflop" then return "FLIP / FLOP" end
    return shortcut.label or "Shortcut"
end

function CP:CombatShortcutLabel(shortcut)
    if type(shortcut) ~= "table" then return "Shortcut" end
    local who = shortcut.recipientLabel or "Bots"
    local kind = shortcut.kind
    if kind == "summon" then return "SUMMON\n" .. who end
    if kind == "order" then return who .. "\n" .. string.upper(tostring(shortcut.order or "ORDER")) end
    if kind == "goto" then return who .. "\nGO TO" end
    if kind == "move" then return who .. "\nMOVE -> L" .. tostring(shortcut.slot or "?") end
    if kind == "set_location" then return "SET LOCATION\nL" .. tostring(shortcut.slot or "?") end
    if kind == "clear_location" then return "CLEAR LOCATION\nL" .. tostring(shortcut.slot or "?") end
    if kind == "rti_assign" then return who .. "\nRTI " .. string.upper(tostring(shortcut.icon or "RTI")) end
    if kind == "rti_run" then return who .. "\n" .. string.upper(tostring(shortcut.mode or "RTI")) .. " RTI" end
    if kind == "strategy" then return who .. "\n" .. tostring(shortcut.actionLabel or shortcut.label or "STRATEGY") end
    if kind == "combat" then return who .. "\n" .. tostring(shortcut.actionLabel or shortcut.command or "COMMAND") end
    if kind == "formation" then return who .. "\n" .. string.upper(tostring(shortcut.formation or "FORMATION")) end
    if kind == "flipflop" then return "FLIP / FLOP" end
    return shortcut.label or "Shortcut"
end

function CP:NormalizeFrontShortcuts(source)
    source = type(source) == "table" and source or {}
    local keys = {}
    for key, value in pairs(source) do
        local n = tonumber(key)
        if n and n >= 1 and math.floor(n) == n and type(value) == "table" then
            keys[#keys + 1] = n
        end
    end
    table.sort(keys)

    local dense = {}
    for i = 1, #keys do
        if #dense >= MAX_FRONT_SHORTCUTS then break end
        local shortcut = source[keys[i]]
        if type(shortcut) == "table" then
            shortcut = deepCopy(shortcut)
            -- Alpha5-10.3 sometimes persisted the fully formatted display label
            -- into combat shortcuts, so repeated renders could prefix the
            -- recipient more than once. Keep semantic data and derive labels
            -- only when rendering.
            if shortcut.kind == "combat" then
                shortcut.actionLabel = shortcut.actionLabel or (shortcut.command and string.upper(tostring(shortcut.command))) or "COMMAND"
                shortcut.label = nil
            elseif shortcut.kind == "strategy" and shortcut.actionLabel then
                shortcut.label = nil
            end
            dense[#dense + 1] = shortcut
        end
    end
    return dense
end

function CP:MarkFrontDirty()
    local db = self:GetDB()
    db.presetDirty = true
    self:RefreshHeaderControls()
end

function CP:MoveShortcut(index, delta)
    local db = self:GetDB()
    index = tonumber(index)
    delta = tonumber(delta) or 0
    local target = index and (index + delta) or nil
    if not index or not target or not db.frontShortcuts[index] or not db.frontShortcuts[target] then return false end
    db.frontShortcuts[index], db.frontShortcuts[target] = db.frontShortcuts[target], db.frontShortcuts[index]
    self:MarkFrontDirty()
    self:SetStatus("Moved front-page slot " .. tostring(index) .. " to " .. tostring(target) .. ".")
    self:SetWorkflow("manage_front", { configuring = true })
    return true
end

function CP:ClearFrontPage()
    local db = self:GetDB()
    db.frontShortcuts = {}
    self:MarkFrontDirty()
    self:SetStatus("Front page cleared. Save the preset to keep this change.")
    self:SetWorkflow("manage_front", { configuring = true })
end

function CP:AddShortcut(shortcut)
    local db = self:GetDB()
    db.frontShortcuts = self:NormalizeFrontShortcuts(db.frontShortcuts)

    local slot
    for i = 1, MAX_FRONT_SHORTCUTS do
        if db.frontShortcuts[i] == nil then slot = i; break end
    end
    if not slot then
        self:SetStatus("Front page is full (" .. MAX_FRONT_SHORTCUTS .. " shortcuts). Remove or reorder one in Planner > Front Page Layout.")
        return false
    end

    shortcut = deepCopy(shortcut or {})
    if shortcut.kind == "combat" then
        shortcut.actionLabel = shortcut.actionLabel or shortcut.label or (shortcut.command and string.upper(tostring(shortcut.command))) or "COMMAND"
        shortcut.label = nil
    end
    db.frontShortcuts[slot] = shortcut
    self:MarkFrontDirty()
    self:SetStatus("Added to front-page slot " .. tostring(slot) .. ": " .. self:ShortcutLabel(shortcut))
    self:SetWorkflow("config_root", { configuring = true })
    return true
end

function CP:RemoveShortcut(index, keepFront)
    local db = self:GetDB()
    index = tonumber(index)
    if not index or not db.frontShortcuts[index] then return false end
    local label = self:ShortcutLabel(db.frontShortcuts[index])
    table.remove(db.frontShortcuts, index)
    self:MarkFrontDirty()
    self:SetStatus("Removed shortcut: " .. label)
    if keepFront then
        self:SetWorkflow("front")
    else
        self:SetWorkflow("manage_front", { configuring = true })
    end
    return true
end

function CP:ShowFrontContextMenu(index)
    index = tonumber(index)
    local db = self:GetDB()
    local shortcut = index and db.frontShortcuts[index] or nil
    if not shortcut or (self.workflow and self.workflow.mode) ~= "front" then return end

    if type(CloseDropDownMenus) == "function" then CloseDropDownMenus() end
    if type(EasyMenu) ~= "function" then
        self:SetStatus("Shortcut context menu is unavailable on this client.")
        return
    end

    if not self.frontContextMenu then
        self.frontContextMenu = CreateFrame(
            "Frame",
            "ElvUI_Multibot_CommandPanelFrontContextMenu",
            E.UIParent,
            "UIDropDownMenuTemplate"
        )
    end

    local label = self:ShortcutLabel(shortcut)
    local menu = {
        {
            text = label,
            isTitle = true,
            notCheckable = true,
        },
        {
            text = "Remove",
            notCheckable = true,
            func = function()
                if type(CloseDropDownMenus) == "function" then CloseDropDownMenus() end
                CP:RemoveShortcut(index, true)
            end,
        },
    }

    EasyMenu(menu, self.frontContextMenu, "cursor", 0, 0, "MENU", 2)
end

function CP:GetPresetNames()
    local names = {}
    for name in pairs(self:GetDB().presets or {}) do names[#names + 1] = name end
    table.sort(names, function(a, b) return string.lower(a) < string.lower(b) end)
    return names
end

function CP:SavePreset(name)
    name = trim(name)
    if name == "" then self:SetStatus("Preset name is required."); return false end
    if #name > 32 then name = string.sub(name, 1, 32) end
    local db = self:GetDB()
    local exists = db.presets[name] ~= nil
    if not exists and #self:GetPresetNames() >= MAX_PRESETS then
        self:SetStatus("Preset limit reached (" .. MAX_PRESETS .. "). Delete one first.")
        return false
    end
    db.frontShortcuts = self:NormalizeFrontShortcuts(db.frontShortcuts)
    db.presets[name] = { shortcuts = deepCopy(db.frontShortcuts), savedAt = time and time() or nil }
    db.activePreset = name
    db.presetDirty = false
    self:SetStatus((exists and "Updated preset: " or "Saved preset: ") .. name)
    self:RefreshHeaderControls()
    self:Render()
    return true
end

function CP:LoadPreset(name)
    local db = self:GetDB()
    local preset = db.presets and db.presets[name]
    if type(preset) ~= "table" or type(preset.shortcuts) ~= "table" then
        self:SetStatus("Preset not found: " .. tostring(name))
        return false
    end
    db.frontShortcuts = self:NormalizeFrontShortcuts(preset.shortcuts)
    db.activePreset = name
    db.presetDirty = false
    self:SetStatus("Loaded preset: " .. name)
    if self:IsPlannerMode() then
        self:SetWorkflow("config_root", { configuring = true })
    else
        self:SetWorkflow("front")
    end
    return true
end

function CP:DeletePreset(name)
    local db = self:GetDB()
    if not db.presets or not db.presets[name] then return false end
    db.presets[name] = nil
    if db.activePreset == name then
        db.activePreset = nil
        db.presetDirty = true
    end
    self:SetStatus("Deleted preset: " .. tostring(name) .. ". Current front page was kept as unsaved.")
    self:RefreshHeaderControls()
    if self:IsPlannerMode() then self:SetWorkflow("config_root", { configuring = true }) else self:Render() end
    return true
end

function CP:CreatePresetDialog()
    if self.presetDialog then return self.presetDialog end
    local f = CreateFrame("Frame", "ElvUI_Multibot_CommandPanelPresetDialog", E.UIParent)
    SetFrameSize(f, 330, 126)
    f:SetPoint("CENTER", E.UIParent, "CENTER", 0, 80)
    f:SetFrameStrata("DIALOG")
    if f.SetTemplate then f:SetTemplate("Transparent") end
    f:Hide()

    f.title = f:CreateFontString(nil, "OVERLAY")
    f.title:SetPoint("TOP", f, "TOP", 0, -12)
    SetUIFont(f.title, 13)
    f.title:SetText("Save Encounter Preset")

    f.edit = CreateFrame("EditBox", "ElvUI_Multibot_CommandPanelPresetEditBox", f, "InputBoxTemplate")
    SetFrameSize(f.edit, 276, 24)
    f.edit:SetPoint("TOP", f.title, "BOTTOM", 0, -12)
    f.edit:SetAutoFocus(false)
    f.edit:SetMaxLetters(32)

    f.save = CreateFrame("Button", nil, f)
    SetFrameSize(f.save, 118, 25)
    f.save:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 32, 12)
    if f.save.SetTemplate then f.save:SetTemplate("Default") end
    f.save.text = f.save:CreateFontString(nil, "OVERLAY")
    f.save.text:SetPoint("CENTER")
    SetUIFont(f.save.text, 11)
    f.save.text:SetText("SAVE PRESET")

    f.cancel = CreateFrame("Button", nil, f)
    SetFrameSize(f.cancel, 118, 25)
    f.cancel:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -32, 12)
    if f.cancel.SetTemplate then f.cancel:SetTemplate("Default") end
    f.cancel.text = f.cancel:CreateFontString(nil, "OVERLAY")
    f.cancel.text:SetPoint("CENTER")
    SetUIFont(f.cancel.text, 11)
    f.cancel.text:SetText("CANCEL")

    local function saveNow()
        local name = trim(f.edit:GetText())
        if self:SavePreset(name) then f:Hide() end
    end
    f.save:SetScript("OnClick", saveNow)
    f.cancel:SetScript("OnClick", function() f:Hide() end)
    f.edit:SetScript("OnEnterPressed", saveNow)
    f.edit:SetScript("OnEscapePressed", function() f:Hide() end)

    self.presetDialog = f
    return f
end

function CP:ShowPresetDialog(saveAs)
    local f = self:CreatePresetDialog()
    if saveAs then
        f.edit:SetText("")
    else
        f.edit:SetText(self:GetDB().activePreset or "")
    end
    f:Show()
    f.edit:SetFocus()
    f.edit:HighlightText()
end

function CP:CreateDeletePresetDialog()
    if self.deletePresetDialog then return self.deletePresetDialog end
    local f = CreateFrame("Frame", "ElvUI_Multibot_CommandPanelDeletePresetDialog", E.UIParent)
    SetFrameSize(f, 340, 118)
    f:SetPoint("CENTER", E.UIParent, "CENTER", 0, 80)
    f:SetFrameStrata("DIALOG")
    if f.SetTemplate then f:SetTemplate("Transparent") end
    f:Hide()

    f.title = f:CreateFontString(nil, "OVERLAY")
    f.title:SetPoint("TOP", f, "TOP", 0, -14)
    SetUIFont(f.title, 13)
    f.title:SetText("Delete preset?")

    f.message = f:CreateFontString(nil, "OVERLAY")
    f.message:SetPoint("TOP", f.title, "BOTTOM", 0, -9)
    f.message:SetPoint("LEFT", f, "LEFT", 16, 0)
    f.message:SetPoint("RIGHT", f, "RIGHT", -16, 0)
    f.message:SetJustifyH("CENTER")
    SetUIFont(f.message, 11)

    f.delete = CreateFrame("Button", nil, f)
    SetFrameSize(f.delete, 118, 25)
    f.delete:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 32, 12)
    if f.delete.SetTemplate then f.delete:SetTemplate("Default") end
    f.delete.text = f.delete:CreateFontString(nil, "OVERLAY")
    f.delete.text:SetPoint("CENTER")
    SetUIFont(f.delete.text, 11)
    f.delete.text:SetText("DELETE")

    f.cancel = CreateFrame("Button", nil, f)
    SetFrameSize(f.cancel, 118, 25)
    f.cancel:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -32, 12)
    if f.cancel.SetTemplate then f.cancel:SetTemplate("Default") end
    f.cancel.text = f.cancel:CreateFontString(nil, "OVERLAY")
    f.cancel.text:SetPoint("CENTER")
    SetUIFont(f.cancel.text, 11)
    f.cancel.text:SetText("CANCEL")

    f.delete:SetScript("OnClick", function()
        local name = f.presetName
        if name and CP:DeletePreset(name) then f:Hide() end
    end)
    f.cancel:SetScript("OnClick", function() f:Hide() end)

    self.deletePresetDialog = f
    return f
end

function CP:ShowDeletePresetDialog()
    local name = self:GetDB().activePreset
    if not name or not self:GetDB().presets[name] then
        self:SetStatus("No saved preset is currently selected.")
        return
    end
    local f = self:CreateDeletePresetDialog()
    f.presetName = name
    f.message:SetText("Delete '" .. tostring(name) .. "'? The current front page will stay loaded as unsaved.")
    f:Show()
end

function CP:IsPlannerMode()
    return (self.workflow and self.workflow.mode or "front") ~= "front"
end

function CP:GetPresetDisplayName()
    local db = self:GetDB()
    if db.activePreset and db.presets[db.activePreset] then
        return db.activePreset .. (db.presetDirty and " *" or "")
    end
    if #self:GetPresetNames() > 0 then return "Custom / Unsaved" end
    return "No saved presets"
end

function CP:PopulatePresetDropdown()
    if type(UIDropDownMenu_CreateInfo) ~= "function" or type(UIDropDownMenu_AddButton) ~= "function" then return end
    local names = self:GetPresetNames()
    if #names == 0 then
        local info = UIDropDownMenu_CreateInfo()
        info.text = "No saved presets"
        info.disabled = true
        UIDropDownMenu_AddButton(info)
        return
    end
    local active = self:GetDB().activePreset
    for i = 1, #names do
        local name = names[i]
        local info = UIDropDownMenu_CreateInfo()
        info.text = name
        info.checked = active == name
        info.func = function() CP:LoadPreset(name) end
        UIDropDownMenu_AddButton(info)
    end
end

local function SetHeaderButtonEnabled(button, enabled)
    if not button then return end
    if enabled then
        button:Enable()
        button:SetAlpha(1)
    else
        button:Disable()
        button:SetAlpha(0.35)
    end
end

function CP:RefreshHeaderControls()
    if not self.frame then return end
    local f = self.frame
    local db = self:GetDB()
    local planner = self:IsPlannerMode()

    if f.presetDropdown and type(UIDropDownMenu_SetText) == "function" then
        UIDropDownMenu_SetText(f.presetDropdown, self:GetPresetDisplayName())
    elseif f.presetFallback and f.presetFallback.text then
        f.presetFallback.text:SetText(self:GetPresetDisplayName())
    end

    if f.modeButton and f.modeButton.text then
        f.modeButton.text:SetText(planner and "COMBAT" or "PLAN")
    end

    if planner then
        if f.saveButton then f.saveButton:Show() end
        if f.saveAsButton then f.saveAsButton:Show() end
        if f.deleteButton then f.deleteButton:Show() end
        SetHeaderButtonEnabled(f.saveButton, #db.frontShortcuts > 0 or db.activePreset ~= nil)
        SetHeaderButtonEnabled(f.saveAsButton, #db.frontShortcuts > 0)
        SetHeaderButtonEnabled(f.deleteButton, db.activePreset ~= nil and db.presets[db.activePreset] ~= nil)
    else
        if f.saveButton then f.saveButton:Hide() end
        if f.saveAsButton then f.saveAsButton:Hide() end
        if f.deleteButton then f.deleteButton:Hide() end
    end
end

function CP:EnterPlanner()
    -- Planner is deliberately a pre-fight surface. Rebuilding/relaying protected
    -- RTSC buttons during combat lockdown can taint the panel on 3.3.5a.
    if type(InCombatLockdown) == "function" and InCombatLockdown() then
        self:SetStatus("Planner is locked during combat. Use the Combat Front Page; configure after combat.")
        return false
    end
    self:SetWorkflow("config_root", { configuring = true })
    return true
end

function CP:EnterCombat()
    self:SetWorkflow("front")
end

function CP:MakeRecipientShortcut(recipient, kind, extra)
    local shortcut = self:RecipientForShortcut(recipient)
    shortcut.kind = kind
    for k, v in pairs(extra or {}) do shortcut[k] = v end
    if kind == "combat" then
        shortcut.actionLabel = shortcut.actionLabel or shortcut.label or (shortcut.command and string.upper(tostring(shortcut.command))) or "COMMAND"
        shortcut.label = nil
    end
    return shortcut
end

function CP:ExecuteShortcut(shortcut)
    if type(shortcut) ~= "table" then return end
    local kind = shortcut.kind
    local recipient = (shortcut.spec or shortcut.frozen) and self:ResolveShortcutRecipient(shortcut) or nil
    if recipient and (not recipient.frozen or #recipient.frozen == 0) then
        self:SetStatus("No bots resolve for shortcut: " .. self:ShortcutLabel(shortcut))
        return
    end

    if kind == "summon" then
        self:SummonRecipients(recipient)
    elseif kind == "order" then
        self:OrderMovement(recipient, shortcut.order)
    elseif kind == "move" then
        self:MoveToSlot(recipient, tonumber(shortcut.slot), true)
    elseif kind == "clear_location" then
        local txId, err = self.API:UnsaveRTSCLocation(MODULE, tonumber(shortcut.slot))
        if txId then
            self.knownSlots[tonumber(shortcut.slot)] = nil
            self:SetStatus("Clear location " .. tostring(shortcut.slot) .. " sent (best effort).")
            self:Render()
        else
            self:SetStatus("Clear refused: " .. tostring(err or "unknown error"))
        end
    elseif kind == "rti_assign" then
        self:AssignRTI(recipient, shortcut.purpose, shortcut.icon)
    elseif kind == "rti_run" then
        self:RunRTI(recipient, shortcut.mode)
    elseif kind == "strategy" then
        self:ExecuteStrategy(recipient.frozen, shortcut.stateScope or "N", shortcut.changes, shortcut.label or "Strategy")
    elseif kind == "combat" then
        self:ExecuteCombatCommand(recipient, shortcut.command, shortcut.label or shortcut.command)
    elseif kind == "formation" then
        local txId, err = self.API:Execute(MODULE, "FORMATION.SET", shortcut.spec, { scope = "GROUP", formation = shortcut.formation })
        if txId then self:SetStatus(recipient.label .. " formation -> " .. shortcut.formation .. ".")
        else self:SetStatus("Formation refused: " .. tostring(err or "unknown error")) end
    elseif kind == "flipflop" then
        self:FlipFlop()
    elseif kind == "goto" or kind == "set_location" then
        self:SetStatus("This placement shortcut must be used from its secure front-page button.")
    end
end

function CP:Preflight(actionId, targetSpec, args)
    if not self.API or not self.API.GetActionAvailability then return true end
    local result = self.API:GetActionAvailability(actionId, targetSpec, args)
    if type(result) == "boolean" then return result, result and nil or "Unavailable" end
    if type(result) == "table" then
        local ok = result.enabled
        if ok == nil then ok = result.available end
        if ok == nil then ok = result.ok end
        if ok == nil then ok = result.allowed end
        if ok == nil then ok = true end
        return ok == true, result.reason or result.message or result.code
    end
    return true
end

function CP:ExecuteSet(actionId, frozen, args, label)
    if not frozen or #frozen == 0 then
        self:SetStatus("No applicable bots.")
        return nil
    end

    local ok, reason = self:Preflight(actionId, frozen, args)
    if not ok then
        self:SetStatus((label or actionId) .. " unavailable: " .. tostring(reason or "preflight refused"))
        return nil
    end

    local txId, err
    if #frozen == 1 and self.API.Execute then
        txId, err = self.API:Execute(MODULE, actionId, frozen[1], args)
    elseif self.API.ExecuteSet then
        txId, err = self.API:ExecuteSet(MODULE, actionId, frozen, args)
    else
        txId, err = self.API:Execute(MODULE, actionId, frozen, args)
    end

    if not txId then
        self:SetStatus((label or actionId) .. " refused: " .. tostring(err or "unknown error"))
        return nil
    end

    self:SetStatus((label or actionId) .. " sent to " .. #frozen .. " bot(s).")
    return txId
end

function CP:ExecuteCombatCommand(recipient, command, label)
    local frozen = recipient.frozen or self:FreezeTarget(recipient.spec)
    if not frozen or #frozen == 0 then
        self:SetStatus("No applicable bots for " .. tostring(recipient.label or recipient.spec) .. ".")
        return
    end
    self:ExecuteSet("COMBAT.COMMAND", frozen, { command = command }, label)
end

function CP:ExecuteStrategy(frozen, stateScope, changes, label)
    return self:ExecuteSet("STRATEGY.MUTATE", frozen, {
        stateScope = stateScope,
        changes = changes,
    }, label)
end

function CP:AssignRTI(recipient, purpose, icon)
    local frozen = recipient.frozen or self:FreezeTarget(recipient.spec)
    if not frozen or #frozen == 0 then
        self:SetStatus("No applicable bots.")
        return
    end
    local txId, err = self.API:AssignRTI(MODULE, frozen, purpose, icon)
    if txId then
        self:SetStatus(recipient.label .. " -> " .. purpose .. " RTI: " .. icon .. ".")
    else
        self:SetStatus("RTI assignment refused: " .. tostring(err or "unknown error"))
    end
end

function CP:RunRTI(recipient, mode)
    if string.upper(tostring(mode or "")) == "PULL" then
        self:RunPullAssigned(recipient)
        return
    end
    local frozen = recipient.frozen or self:FreezeTarget(recipient.spec)
    if not frozen or #frozen == 0 then
        self:SetStatus("No applicable bots.")
        return
    end
    local txId, err = self.API:RunAssignedRTI(MODULE, frozen, mode)
    if txId then
        self:SetStatus(recipient.label .. " -> " .. mode .. " assigned RTI.")
    else
        self:SetStatus("RTI " .. mode .. " refused: " .. tostring(err or "unknown error"))
    end
end

function CP:DispatchMoveToSlot(recipient, frozen, slot, track)
    local ok, reason = self:Preflight("RTSC.GO", frozen, { slot = slot })
    if not ok then
        self:SetStatus("Move unavailable: " .. tostring(reason or "preflight refused"))
        return false
    end

    local txId, err = self.API:GoRTSCLocation(MODULE, frozen, slot)
    if txId then
        self:SetStatus(recipient.label .. " staying at location " .. slot .. " (best effort).")
        if track and slot >= 1 and slot <= 8 then
            self:TrackPositionOrder(recipient.label, frozen, slot)
        end
        return true
    end

    self:SetStatus("Move refused: " .. tostring(err or "unknown error"))
    return false
end

function CP:MoveToSlot(recipient, slot, track)
    local frozen = recipient.frozen or self:FreezeTarget(recipient.spec)
    if not frozen or #frozen == 0 then
        self:SetStatus("No applicable bots.")
        return
    end

    slot = tonumber(slot)
    if not slot then self:SetStatus("Move unavailable: invalid location."); return end

    local ok, reason = self:Preflight("RTSC.GO", frozen, { slot = slot })
    if not ok then
        self:SetStatus("Move unavailable: " .. tostring(reason or "preflight refused"))
        return
    end

    local frozenCopy = shallowCopyArray(frozen)
    local recipientCopy = {
        label = recipient.label,
        spec = recipient.spec,
        frozen = frozenCopy,
        movementMode = recipient.movementMode,
    }

    local barrier, err = self:BeginStayBarrier(recipientCopy, function(doneBarrier)
        if doneBarrier.failed and doneBarrier.failed > 0 then
            CP:SetStatus("Move stopped: Stay failed for " .. tostring(doneBarrier.failed) .. " bot(s).")
            return
        end
        CP:DispatchMoveToSlot(recipientCopy, frozenCopy, slot, track)
    end)

    if not barrier then
        self:SetStatus("Move could not set Stay first: " .. tostring(err or "unknown error"))
        return
    end

    barrier.slot = slot
    self.pendingStayMoves[#self.pendingStayMoves + 1] = barrier
    self:SetStatus("Stay sent to " .. tostring(#frozenCopy) .. " bot(s); moving to location " .. tostring(slot) .. " when ready.")
end

function CP:TrackPositionOrder(label, frozen, slot)
    local key = self:FrozenKey(frozen)
    if not key then return end

    local existing
    for i = 1, #self.positionHistory do
        if self.positionHistory[i].key == key then
            existing = table.remove(self.positionHistory, i)
            break
        end
    end

    existing = existing or {}
    existing.key = key
    existing.label = label
    existing.frozen = shallowCopyArray(frozen)
    existing.slot = slot
    existing.orderedAt = GetTime and GetTime() or 0
    self.positionHistory[#self.positionHistory + 1] = existing

    while #self.positionHistory > 2 do table.remove(self.positionHistory, 1) end

    self.flipPair = nil
    if #self.positionHistory == 2 then
        local a, b = self.positionHistory[1], self.positionHistory[2]
        if a.key ~= b.key and a.slot ~= b.slot then
            self.flipPair = { a = a, b = b }
        end
    end

    self:Render()
end

function CP:FlipFlop()
    local pair = self.flipPair
    if not pair then
        self:SetStatus("Flip/Flop is not armed yet.")
        return
    end

    local a, b = pair.a, pair.b
    local aOld, bOld = a.slot, b.slot

    local txA, errA = self.API:GoRTSCLocation(MODULE, a.frozen, bOld)
    local txB, errB = self.API:GoRTSCLocation(MODULE, b.frozen, aOld)

    if txA and txB then
        a.slot, b.slot = bOld, aOld
        self:SetStatus("Flip/Flop sent: " .. a.label .. " -> " .. a.slot .. ", " .. b.label .. " -> " .. b.slot .. ".")
        self:Render()
    else
        self:SetStatus("Flip/Flop incomplete: " .. tostring(errA or errB or "one movement was refused"))
    end
end

function CP:GetRTIIcons()
    if self.API and self.API.GetRTIIcons then
        local icons = self.API:GetRTIIcons()
        if type(icons) == "table" and #icons > 0 then return icons end
    end
    return FALLBACK_RTI
end

function CP:HasAEDMSpell()
    if type(GetNumSpellTabs) ~= "function" or type(GetSpellTabInfo) ~= "function" or type(GetSpellName) ~= "function" then
        return false
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

function CP:EnsureRTSCEnabled()
    if self:HasAEDMSpell() then
        self.rtscEnableRequest = nil
        return true, "AEDM_PRESENT"
    end

    if not self.API or type(self.API.EnableRTSC) ~= "function" then
        return false, "RTSC_ENABLE_API_UNAVAILABLE"
    end

    local now = GetTime and GetTime() or 0
    if self.rtscEnableRequest and (now - (self.rtscEnableRequest.requestedAt or 0)) < 5.0 then
        return true, "ENABLE_PENDING"
    end

    local ok, reason = self:Preflight("RTSC.ENABLE", "all", {})
    if not ok then return false, reason or "RTSC_ENABLE_UNAVAILABLE" end

    local txId, err = self.API:EnableRTSC(MODULE)
    if not txId then return false, err or "RTSC_ENABLE_REFUSED" end

    self.rtscEnableRequest = { txId = txId, requestedAt = now }
    return true, "ENABLE_REQUESTED"
end

function CP:GetGridCellGeometry(cell)
    local db = self:GetDB()
    local mode = self.workflow and self.workflow.mode or "front"
    local cols = 3
    local h = db.buttonHeight or 28

    if mode == "front" then
        cols = 2
        h = db.frontButtonHeight or 42
    elseif mode == "config_root" then
        cols = 2
        h = math.max(34, db.buttonHeight or 28)
    elseif mode == "manage_front" then
        cols = 2
        h = math.max(32, db.buttonHeight or 28)
    elseif mode == "layout_edit" then
        cols = 2
        h = math.max(32, db.buttonHeight or 28)
    end

    local index = math.max(0, (tonumber(cell) or 1) - 1)
    local row = math.floor(index / cols)
    local col = index % cols
    local spacing = db.spacing or 5
    local contentWidth = self.frame and self.frame.content and self.frame.content:GetWidth() or ((db.width or 500) - 20)
    local width = (contentWidth - spacing * (cols - 1)) / cols
    return col * (width + spacing), -row * (h + spacing), width, h
end

function CP:LayoutSecureGrid()
    if not self.frame or not self.frame.content then return end
    for cell = 1, 8 do
        local x, y, width, h = self:GetGridCellGeometry(cell)
        local button = self.secureGridButtons[cell]
        local cover = self.secureGridCovers[cell]
        if button then
            button:ClearAllPoints()
            SetFrameSize(button, width, h)
            button:SetPoint("TOPLEFT", self.frame.content, "TOPLEFT", x, y)
        end
        if cover then
            cover:ClearAllPoints()
            SetFrameSize(cover, width, h)
            cover:SetPoint("TOPLEFT", self.frame.content, "TOPLEFT", x, y)
        end
    end
end

function CP:CreateSecureGrid()
    if not self.frame or not self.frame.content or self.secureGridButtons[1] then return end

    for cell = 1, 8 do
        local button = CreateFrame(
            "Button",
            "ElvUI_Multibot_CommandPanelRTSCGrid" .. tostring(cell),
            self.frame.content,
            "SecureActionButtonTemplate"
        )
        if button.SetTemplate then button:SetTemplate("Default") end
        if button.RegisterForClicks then button:RegisterForClicks("LeftButtonUp", "RightButtonUp") end
        button:SetFrameLevel((self.frame.content:GetFrameLevel() or 0) + 2)
        button.text = button:CreateFontString(nil, "OVERLAY")
        button.text:SetPoint("CENTER")
        SetUIFont(button.text, self:GetDB().fontSize or 12)
        button.text:SetText("")
        button.mbcpCell = cell
        button:SetScript("PreClick", function(selfButton, mouseButton)
            selfButton.mbcpPrepared = false
            selfButton.mbcpPrepareReason = nil
            if mouseButton ~= "LeftButton" then return end
            local ok, reason = CP:PrepareGridSecureClick(selfButton.mbcpCell)
            selfButton.mbcpPrepared = ok == true
            selfButton.mbcpPrepareReason = reason
        end)
        button:SetScript("PostClick", function(selfButton, mouseButton)
            if mouseButton == "RightButton" then
                if CP.workflow and CP.workflow.mode == "front" then
                    CP:ShowFrontContextMenu(selfButton.mbcpCell)
                end
                return
            end
            if mouseButton ~= "LeftButton" then return end
            CP:FinishGridSecureClick(selfButton.mbcpCell, selfButton.mbcpPrepared, selfButton.mbcpPrepareReason)
        end)
        button:Show()
        self.secureGridButtons[cell] = button

        local cover = CreateFrame("Button", nil, self.frame.content)
        cover:SetFrameLevel((self.frame.content:GetFrameLevel() or 0) + 4)
        if cover.RegisterForClicks then cover:RegisterForClicks("LeftButtonUp", "RightButtonUp") end
        cover.text = cover:CreateFontString(nil, "OVERLAY")
        cover.text:SetPoint("CENTER")
        SetUIFont(cover.text, self:GetDB().fontSize or 12)
        cover.text:SetText("")
        cover.mbcpCell = cell
        cover:SetScript("OnClick", function(selfCover, mouseButton)
            if mouseButton == "RightButton" then
                if CP.workflow and CP.workflow.mode == "front" and CP.frontSecureActions[selfCover.mbcpCell] then
                    CP:ShowFrontContextMenu(selfCover.mbcpCell)
                end
                return
            end
            if mouseButton ~= "LeftButton" then return end
            if not CP.secureReady then
                local secureOK, secureReason = CP:SetupSecurePlacementButtons()
                if not secureOK then
                    CP:SetStatus("RTSC secure placement unavailable: " .. tostring(secureReason or CP.secureSetupReason or "unknown error"))
                    return
                end
                CP:SetStatus("RTSC secure placement recovered. Click the shortcut again to place.")
                return
            end

            local shortcut = CP.workflow and CP.workflow.mode == "front" and CP.frontSecureActions[selfCover.mbcpCell] or nil
            if shortcut and shortcut.kind == "goto" and not CP.scratchPrimed then
                local primed, primeReason = CP:PrimeScratchSlot("cover_click")
                CP:RefreshSecureGrid()
                if primed then
                    CP:SetStatus("GO TO scratch location is armed. Click GO TO again, then click the world.")
                else
                    CP:SetStatus("GO TO scratch arm failed: " .. tostring(primeReason or "unknown error"))
                end
                return
            end

            local enabled, reason = CP:EnsureRTSCEnabled()
            if enabled then
                CP:SetStatus("RTSC is preparing AEDM. The placement button will arm automatically.")
            else
                CP:SetStatus("RTSC enable unavailable: " .. tostring(reason or "unknown error"))
            end
        end)
        cover:Show()
        self.secureGridCovers[cell] = cover
    end

    self:LayoutSecureGrid()
end

function CP:RefreshSecureGrid()
    if not self.frame then return end

    local db = self:GetDB()
    local fontSize = db.fontSize or 12
    for cell = 1, 8 do
        local button = self.secureGridButtons[cell]
        local cover = self.secureGridCovers[cell]
        if button and button.text then
            SetUIFont(button.text, fontSize)
            button.text:SetText("")
            button:SetAlpha(0)
        end
        if cover and cover.text then
            SetUIFont(cover.text, fontSize)
            cover.text:SetText("")
            cover:Hide()
        end
    end

    local w = self.workflow or {}

    -- Secure RTSC shortcuts are stored correctly even when the protected
    -- hardware-click layer could not be configured yet. Never render those
    -- cells as blank: expose their labels through the ordinary cover and make
    -- the failure explicit until secure setup recovers.
    if not self.secureReady then
        if w.mode == "front" then
            for cell = 1, 8 do
                local shortcut = self.frontSecureActions[cell]
                local cover = self.secureGridCovers[cell]
                if shortcut and cover and cover.text then
                    cover.text:SetText(self:CombatShortcutLabel(shortcut) .. "\nRTSC NOT READY")
                    cover:Show()
                end
            end
        end
        return
    end

    local ready = self:HasAEDMSpell()
    if w.mode == "front" then
        for cell = 1, 8 do
            local shortcut = self.frontSecureActions[cell]
            if shortcut then
                local button = self.secureGridButtons[cell]
                local cover = self.secureGridCovers[cell]
                local label = self:CombatShortcutLabel(shortcut)
                local cellReady = ready and (shortcut.kind ~= "goto" or self.scratchPrimed)
                if button and button.text then button.text:SetText(label); button:SetAlpha(1) end
                if cover and cover.text then
                    if not ready then
                        cover.text:SetText(label .. " (RTSC...)")
                    elseif shortcut.kind == "goto" and not self.scratchPrimed then
                        cover.text:SetText(label .. "\nARMING...")
                    else
                        cover.text:SetText("")
                    end
                    if cellReady then cover:Hide() else cover:Show() end
                end
            end
        end
    elseif w.mode == "position_actions" and w.configuring ~= true then
        local button = self.secureGridButtons[3]
        local cover = self.secureGridCovers[3]
        if button and button.text then button.text:SetText("GO TO"); button:SetAlpha(1) end
        if cover and cover.text then
            cover.text:SetText(ready and "" or "GO TO (RTSC...)")
            if ready then cover:Hide() else cover:Show() end
        end
    elseif w.mode == "position_slots" and w.action == "set" and w.configuring ~= true then
        for cell = 1, 8 do
            local button = self.secureGridButtons[cell]
            local cover = self.secureGridCovers[cell]
            local known = self.knownSlots[cell]
            local label = "Location " .. tostring(cell) .. (known and " *" or "")
            if button and button.text then button.text:SetText(label); button:SetAlpha(1) end
            if cover and cover.text then
                cover.text:SetText(ready and "" or (label .. " (RTSC...)"))
                if ready then cover:Hide() else cover:Show() end
            end
        end
    end
end

function CP:BeginStrategyBarrier(frozen, changes, label, onReady)
    if not frozen or #frozen == 0 then return nil, "NO_TARGETS" end
    if not self.API or not self.API.ExecuteSet then return nil, "STRATEGY_API_UNAVAILABLE" end

    local barrier = {
        expected = #frozen,
        completed = 0,
        failed = 0,
        seen = {},
        startedAt = GetTime and GetTime() or 0,
        done = false,
        label = label,
    }

    local function finishIfReady()
        if barrier.done or barrier.completed < barrier.expected then return end
        barrier.done = true
        if type(onReady) == "function" then
            onReady(barrier)
        end
    end

    local ids, err = self.API:ExecuteSet(
        MODULE,
        "STRATEGY.MUTATE",
        frozen,
        { stateScope = "N", changes = changes },
        function(tx)
            if type(tx) ~= "table" then return end
            local id = tostring(tx.id or tx.transactionId or "")
            if id ~= "" and barrier.seen[id] then return end
            if id ~= "" then barrier.seen[id] = true end

            local state = tostring(tx.state or "")
            if state == "CONFIRMED" or state == "SENT_UNVERIFIED" then
                barrier.completed = barrier.completed + 1
            elseif state == "FAILED" or state == "CANCELLED" or state == "AMBIGUOUS" then
                barrier.completed = barrier.completed + 1
                barrier.failed = barrier.failed + 1
            else
                return
            end
            finishIfReady()
        end
    )

    if not ids then return nil, err or "STRATEGY_REFUSED" end
    if type(ids) == "table" then
        for _, item in ipairs(ids) do
            if type(item) == "table" and not item.transactionId then
                barrier.completed = barrier.completed + 1
                barrier.failed = barrier.failed + 1
            end
        end
    end
    finishIfReady()
    return barrier
end

function CP:SendTacticalOrder(recipient, order, callback)
    local frozen = recipient and (recipient.frozen or self:FreezeTarget(recipient.spec)) or nil
    if not frozen or #frozen == 0 then
        if callback then callback(false, "NO_TARGETS") end
        return nil, "NO_TARGETS"
    end
    if not self.API or type(self.API.OrderBots) ~= "function" then
        if callback then callback(false, "CORE_1_6_3_REQUIRED") end
        return nil, "CORE_1_6_3_REQUIRED"
    end

    local txId, err = self.API:OrderBots(MODULE, frozen, order, function(tx)
        if type(tx) ~= "table" then return end
        local state = tostring(tx.state or "")
        if state == "SENT_UNVERIFIED" or state == "CONFIRMED" then
            if callback then callback(true, nil, tx) end
        elseif state == "FAILED" or state == "CANCELLED" or state == "AMBIGUOUS" then
            if callback then callback(false, tx.error or state, tx) end
        end
    end)
    if not txId then
        if callback then callback(false, err or "ORDER_REFUSED") end
        return nil, err or "ORDER_REFUSED"
    end
    return txId
end

function CP:BeginStayBarrier(recipient, onReady)
    local frozen = recipient and (recipient.frozen or self:FreezeTarget(recipient.spec)) or nil
    if not frozen or #frozen == 0 then return nil, "NO_TARGETS" end

    local barrier = {
        expected = #frozen,
        completed = 0,
        failed = 0,
        done = false,
        phase = "order",
        startedAt = GetTime and GetTime() or 0,
    }

    local txId, err = self:SendTacticalOrder({
        label = recipient.label,
        spec = recipient.spec,
        frozen = frozen,
    }, "STAY", function(success, orderErr)
        barrier.done = true
        barrier.completed = barrier.expected
        if not success then
            barrier.failed = barrier.expected
            barrier.error = orderErr or "STAY_FAILED"
        end
        if type(onReady) == "function" then onReady(barrier) end
    end)

    if not txId then return nil, err or "STAY_REFUSED" end
    return barrier
end

function CP:OrderMovement(recipient, order, callback)
    order = string.upper(tostring(order or ""))
    local frozen = recipient and (recipient.frozen or self:FreezeTarget(recipient.spec)) or nil
    if not frozen or #frozen == 0 then
        self:SetStatus("No applicable bots.")
        if callback then callback(false, "NO_TARGETS") end
        return
    end

    if order ~= "FOLLOW" and order ~= "STAY" and order ~= "FLEE" and order ~= "RESET" then
        self:SetStatus("Unsupported tactical order: " .. tostring(order))
        if callback then callback(false, "INVALID_ORDER") end
        return
    end

    local txId, err = self:SendTacticalOrder({
        label = recipient.label,
        spec = recipient.spec,
        frozen = frozen,
    }, order, function(success, orderErr)
        if success then
            self:SetStatus(recipient.label .. " -> " .. string.lower(order) .. ".")
            if recipient.spec == "all" and (order == "FOLLOW" or order == "STAY") then
                self.footerNextOrder = order == "FOLLOW" and "STAY" or "FOLLOW"
                self:RefreshCombatFooter()
            end
        else
            self:SetStatus(recipient.label .. " " .. string.lower(order) .. " failed: " .. tostring(orderErr or "unknown error"))
        end
        if callback then callback(success, orderErr) end
    end)

    if not txId then
        self:SetStatus(recipient.label .. " " .. string.lower(order) .. " refused: " .. tostring(err or "unknown error"))
        if callback then callback(false, err or "ORDER_REFUSED") end
    end
    return txId
end

function CP:RunPullAssigned(recipient)
    local frozen = recipient and (recipient.frozen or self:FreezeTarget(recipient.spec)) or nil
    if not frozen or #frozen == 0 then self:SetStatus("No applicable bots."); return end

    -- Stay is a real Playerbots order, so release it with the corresponding
    -- Follow order immediately before the pull. The pull command follows as
    -- soon as Core reports the Follow groupcall/burst sent.
    local txId, err = self:SendTacticalOrder({
        label = recipient.label,
        spec = recipient.spec,
        frozen = frozen,
    }, "FOLLOW", function(success, orderErr)
        if not success then
            self:SetStatus("Pull stopped: could not release Stay: " .. tostring(orderErr or "unknown error"))
            return
        end
        local pullId, pullErr = self.API:RunAssignedRTI(MODULE, frozen, "pull")
        if pullId then
            self:SetStatus(recipient.label .. " released from Stay and pulling assigned RTI.")
        else
            self:SetStatus("Pull refused: " .. tostring(pullErr or "unknown error"))
        end
    end)
    if not txId then
        self:SetStatus("Pull could not release Stay first: " .. tostring(err or "unknown error"))
    end
end

function CP:FrontHasGoToShortcut()
    local db = self:GetDB()
    local shortcuts = db and db.frontShortcuts
    if type(shortcuts) ~= "table" then return false end
    for i = 1, MAX_FRONT_SHORTCUTS do
        local shortcut = shortcuts[i]
        if type(shortcut) == "table" and shortcut.kind == "goto" then
            return true
        end
    end
    return false
end

-- GO TO deliberately uses the proven saved-location path.  Slot 9 is armed
-- *before* the secure button is pressed so the later /cast aedm hardware click
-- never races a chat-side `rtsc save 9` command.  The slot remains reserved as
-- CommandPanel scratch state; saving a waypoint alone cannot move a bot.
function CP:PrimeScratchSlot(reason)
    if self.scratchPrimed then return true, "ALREADY_PRIMED" end
    if self.scratchArmReadyAt then return true, "ARMING" end
    if self.placement then return false, "PLACEMENT_ACTIVE" end
    if not self.API or type(self.API.ArmRTSCLocationImmediate) ~= "function" then
        return false, "CORE_RTSC_ARM_UNAVAILABLE"
    end

    local armed, info = self.API:ArmRTSCLocationImmediate(MODULE, SCRATCH_SLOT, false)
    if not armed then
        self.scratchPrimed = false
        self.scratchArmReadyAt = nil
        return false, info or "SCRATCH_ARM_FAILED"
    end

    -- Sending chat is not proof every bot has processed it.  Keep the secure
    -- GO TO cell covered for a short settle window so `rtsc save 9` is already
    -- server-side before the user is allowed to fire AEDM.
    self.scratchPrimed = false
    self.scratchPrimeDueAt = nil
    self.scratchArmReadyAt = (GetTime and GetTime() or 0) + SCRATCH_ARM_SETTLE
    self.scratchPrimeReason = reason or "primed"
    if not self:HasAEDMSpell() then
        self.rtscEnableRequest = { requestedAt = GetTime and GetTime() or 0 }
    end
    return true, info
end

function CP:MaybePrimeScratchSlot(reason)
    if self.placement then return false, "PLACEMENT_ACTIVE" end
    if self.scratchPrimed or self.scratchArmReadyAt then return true, self.scratchPrimed and "ALREADY_PRIMED" or "ARMING" end
    if not self:FrontHasGoToShortcut() then return false, "NOT_NEEDED" end
    return self:PrimeScratchSlot(reason)
end

function CP:ScheduleScratchPrime(delay, reason)
    self.scratchPrimed = false
    self.scratchArmReadyAt = nil
    self.scratchPrimeDueAt = (GetTime and GetTime() or 0) + (tonumber(delay) or 0.50)
    self.scratchPrimeReason = reason or "scheduled"
    if self.frame then self:RefreshSecureGrid() end
end

function CP:BeginGoToStayBarrier(recipient)
    local barrier, err = self:BeginStayBarrier(recipient, function(done)
        if CP.placement and CP.placement.kind == "goto" and CP.placement.groundPlaced then
            CP:TryDispatchGoTo()
        end
    end)
    self.gotoStayBarrier = barrier
    return barrier, err
end

function CP:PrepareGridSecureClick(cell)
    if not self.API or not self.secureReady then return false, "RTSC_SECURE_UNAVAILABLE" end
    if not self:HasAEDMSpell() then
        self:EnsureRTSCEnabled()
        return false, "AEDM_NOT_READY"
    end
    if type(self.API.ArmRTSCLocationImmediate) ~= "function" then
        return false, "CORE_RTSC_ARM_UNAVAILABLE"
    end

    local w = self.workflow or {}
    local recipient, slot, kind

    if w.mode == "front" then
        local shortcut = self.frontSecureActions[tonumber(cell)]
        if shortcut and shortcut.kind == "goto" then
            recipient, slot, kind = self:ResolveShortcutRecipient(shortcut), SCRATCH_SLOT, "goto"
        elseif shortcut and shortcut.kind == "set_location" then
            slot, kind = tonumber(shortcut.slot), "set"
        else
            return false, "NOT_A_PLACEMENT_CONTROL"
        end
    elseif w.mode == "position_actions" and w.configuring ~= true and tonumber(cell) == 3 then
        recipient, slot, kind = w.recipient, SCRATCH_SLOT, "goto"
    elseif w.mode == "position_slots" and w.configuring ~= true and w.action == "set" and tonumber(cell) and tonumber(cell) >= 1 and tonumber(cell) <= 8 then
        slot, kind = tonumber(cell), "set"
    else
        return false, "NOT_A_PLACEMENT_CONTROL"
    end

    local frozen
    if kind == "goto" then
        frozen = recipient and (recipient.frozen or self:FreezeTarget(recipient.spec)) or nil
        if not frozen or #frozen == 0 then return false, "NO_TARGETS" end

        -- Slot 9 must already be armed before this protected click.  Never send
        -- `rtsc save 9`, `stay`, or `rtsc move` from the same click that casts
        -- AEDM; those chat packets can be processed after the spell click and
        -- produce exactly the intermittent live failures we observed.
        if not self.scratchPrimed then
            self:SetStatus("GO TO scratch location is still arming. Wait for the button to become ready and click again.")
            return false, "SCRATCH_NOT_PRIMED"
        end

        self.scratchGeneration = (tonumber(self.scratchGeneration) or 0) + 1
        local generation = self.scratchGeneration

        -- The current AEDM click consumes the already-armed `save 9` action.
        -- Mark the scratch state unprimed now; it is re-armed only after the
        -- resulting GO command has been sent, ready for the next use.
        self.scratchPrimed = false
        self.scratchPrimeDueAt = nil
        self.scratchArmReadyAt = nil
        self.knownSlots[SCRATCH_SLOT] = nil
        self.placement = {
            recipient = {
                label = recipient.label,
                spec = recipient.spec,
                frozen = shallowCopyArray(frozen),
                movementMode = recipient.movementMode,
            },
            slot = SCRATCH_SLOT,
            kind = "goto",
            secureClicked = false,
            hadTargeting = false,
            clickedAt = nil,
            armedAt = GetTime and GetTime() or 0,
            armInfo = "PREARMED_SAVE_9",
            stayBarrier = nil,
            groundPlaced = false,
            scratchGeneration = generation,
        }
        self:SetStatus("Go To ready for " .. tostring(#frozen) .. " bot(s). Click the destination.")
        return true, "PREARMED_SAVE_9"
    end

    -- Normal named Set Location workflow remains the validated shared RTSC
    -- save operation. Slots 1-8 are not involved in Go To scratch handling.
    self.scratchPrimed = false
    self.scratchPrimeDueAt = nil
    self.scratchArmReadyAt = nil
    local armed, armInfo = self.API:ArmRTSCLocationImmediate(MODULE, slot, true)
    if not armed then
        self:SetStatus("Location " .. tostring(slot) .. " could not be freshly armed: " .. tostring(armInfo or "unknown error"))
        return false, armInfo
    end

    self.knownSlots[slot] = nil
    self.placement = {
        recipient = nil,
        slot = slot,
        kind = "set",
        secureClicked = false,
        hadTargeting = false,
        clickedAt = nil,
        armedAt = GetTime and GetTime() or 0,
        armInfo = armInfo,
        stayBarrier = nil,
        groundPlaced = false,
    }
    self:SetStatus("Location " .. tostring(slot) .. " cleared/re-armed. Click the destination.")
    return true, armInfo
end

function CP:FinishGridSecureClick(cell, prepared, reason)
    if not prepared then
        if reason and reason ~= "NOT_A_PLACEMENT_CONTROL" then
            self:SetStatus("RTSC placement unavailable: " .. tostring(reason))
        end
        return false
    end

    local p = self.placement
    if not p then return false end
    p.secureClicked = true
    p.clickedAt = GetTime and GetTime() or p.armedAt or 0
    p.hadTargeting = type(SpellIsTargeting) == "function" and SpellIsTargeting() and true or false
    return true
end

function CP:CancelPlacement(message)
    local wasGoTo = self.placement and self.placement.kind == "goto"
    self.placement = nil
    self.gotoStayBarrier = nil
    if wasGoTo and not self.scratchPrimed then
        self:ScheduleScratchPrime(0.35, "placement_cancelled")
    end
    if message then self:SetStatus(message) end
    self:RefreshSecureGrid()
end

function CP:CleanupScratchSlot(reason, generation)
    if generation ~= nil and tonumber(generation) ~= tonumber(self.scratchGeneration) then
        return false, "STALE_CLEANUP"
    end
    if self.placement and self.placement.kind == "goto" then
        return false, "PLACEMENT_ACTIVE"
    end
    if not self.API or type(self.API.UnsaveRTSCLocation) ~= "function" then return false, "API_UNAVAILABLE" end
    local txId = self.API:UnsaveRTSCLocation(MODULE, SCRATCH_SLOT)
    if txId then
        self.knownSlots[SCRATCH_SLOT] = nil
        self.lastScratchCleanupAt = GetTime and GetTime() or 0
        return true
    end
    return false, "UNSAVE_REFUSED"
end

function CP:ScheduleScratchCleanup(delay, generation, reason)
    local now = GetTime and GetTime() or 0
    self.scratchCleanup = {
        dueAt = now + (tonumber(delay) or 0.75),
        generation = tonumber(generation) or tonumber(self.scratchGeneration) or 0,
        reason = reason or "scheduled",
    }
end

function CP:TryDispatchGoTo()
    local p = self.placement
    if not p or p.kind ~= "goto" or not p.groundPlaced then return end

    local barrier = p.stayBarrier
    if barrier and not barrier.done then
        self:SetStatus("Destination placed; waiting for Stay to be sent...")
        return
    end
    if barrier and barrier.failed > 0 then
        self:CancelPlacement("Go To stopped: Stay failed for " .. tostring(barrier.failed) .. " bot(s).")
        return
    end

    local recipient = p.recipient
    self.knownSlots[SCRATCH_SLOT] = true
    self.placement = nil
    self.gotoStayBarrier = nil

    -- Block RenderFront's opportunistic pre-arm while the GO transaction is
    -- still entering Core's chat queue.  Otherwise a bypass-throttle save-9
    -- prime can jump ahead of the queued `rtsc go 9` message.
    self.scratchPrimeDueAt = (GetTime and GetTime() or 0) + 2.0
    self.scratchPrimeReason = "goto_dispatch_pending"

    local txId, err = self.API:GoRTSCLocation(MODULE, recipient.frozen, SCRATCH_SLOT, function(tx)
        if type(tx) ~= "table" then return end
        local state = tostring(tx.state or "")
        if state == "SENT_UNVERIFIED" or state == "CONFIRMED" then
            -- Keep slot 9 saved.  A saved waypoint is inert until a GO command
            -- is issued, and keeping it avoids the old unsave/go processing
            -- race.  Re-arm save 9 after the GO has actually left the client so
            -- the next GO TO remains a genuine one-click placement.
            CP:ScheduleScratchPrime(0.35, "post_goto")
            CP:SetStatus("Go To sent to " .. tostring(#recipient.frozen) .. " bot(s).")
        elseif state == "FAILED" or state == "CANCELLED" or state == "AMBIGUOUS" then
            CP:ScheduleScratchPrime(0.35, "goto_failed")
            CP:SetStatus("Go To movement failed: " .. tostring(tx.error or state))
        end
    end)
    if not txId then
        self:ScheduleScratchPrime(0.35, "goto_refused")
        self:SetStatus("Go To placement saved, but movement was refused: " .. tostring(err or "unknown error"))
    else
        self:SetStatus("Destination saved; sending Stay then rtsc go 9 to " .. tostring(#recipient.frozen) .. " bot(s).")
    end
    self:Render()
end

function CP:CompletePlacement()
    local p = self.placement
    if not p then return end

    if p.kind == "set" then
        if p.slot >= 1 and p.slot <= 8 then self.knownSlots[p.slot] = true end
        local slot = p.slot
        self.placement = nil
        self:SetStatus("Location " .. tostring(slot) .. " placed (session-known / best effort).")
        if self:FrontHasGoToShortcut() then
            self:ScheduleScratchPrime(0.35, "after_set_location")
        end
        self:Render()
        return
    end

    if p.kind == "goto" then
        p.groundPlaced = true

        -- The destination now exists in saved slot 9.  Only now issue Stay,
        -- then let the normal Core transaction callback send `rtsc go 9`.
        -- This deliberately places chat commands after the human ground click
        -- instead of racing them against the secure AEDM cast.
        local barrier, err = self:BeginGoToStayBarrier(p.recipient)
        if not barrier then
            self:CancelPlacement("Go To stopped: could not send Stay: " .. tostring(err or "unknown error"))
            self:ScheduleScratchPrime(0.35, "stay_refused")
            return
        end
        p.stayBarrier = barrier
        self:SetStatus("Destination saved; sending Stay before rtsc go 9...")
        self:TryDispatchGoTo()
    end
end

function CP:OnPlacementUpdate(elapsed)
    local now = GetTime and GetTime() or 0

    if self.scratchArmReadyAt and now >= self.scratchArmReadyAt then
        self.scratchArmReadyAt = nil
        self.scratchPrimed = true
        self:RefreshSecureGrid()
    end

    if self.scratchPrimeDueAt and now >= self.scratchPrimeDueAt then
        if self.placement then
            self.scratchPrimeDueAt = now + 0.25
        else
            local reason = self.scratchPrimeReason or "scheduled"
            self.scratchPrimeDueAt = nil
            self:MaybePrimeScratchSlot(reason)
            self:RefreshSecureGrid()
        end
    end

    local cleanup = self.scratchCleanup
    if cleanup and now >= (cleanup.dueAt or now) then
        if tonumber(cleanup.generation) ~= tonumber(self.scratchGeneration) then
            self.scratchCleanup = nil
        elseif self.placement and self.placement.kind == "goto" then
            -- Never clear the scratch slot while a new exact-set placement is
            -- armed or waiting for its world click. Presence/reconnect events
            -- may otherwise destroy the destination underneath the operation.
            cleanup.dueAt = now + 0.50
        else
            self.scratchCleanup = nil
            self:CleanupScratchSlot(cleanup.reason or "scheduled", cleanup.generation)
        end
    end

    if self.rtscEnableRequest then
        if self:HasAEDMSpell() then
            self.rtscEnableRequest = nil
            self:RefreshSecureGrid()
        elseif (now - (self.rtscEnableRequest.requestedAt or now)) >= 5.0 then
            self.rtscEnableRequest = nil
            self:SetStatus("RTSC could not be enabled for placement.")
            self:RefreshSecureGrid()
        end
    end

    local p = self.placement
    if p and p.secureClicked then
        local targeting = type(SpellIsTargeting) == "function" and SpellIsTargeting() and true or false
        if targeting then
            p.hadTargeting = true
        elseif p.hadTargeting and (now - (p.clickedAt or now)) >= 0.10 then
            self:CompletePlacement()
        elseif not p.hadTargeting and (now - (p.clickedAt or now)) >= 5.0 then
            self:CancelPlacement("Location " .. tostring(p.slot) .. " was not placed. Try again.")
        end
    end

    local barrier = self.gotoStayBarrier
    if barrier and not barrier.done and (now - (barrier.startedAt or now)) >= 5.0 then
        if self.placement and self.placement.kind == "goto" then
            self:CancelPlacement("Go To stopped: Stay confirmation timed out.")
        else
            self.gotoStayBarrier = nil
        end
    end

    for i = #self.pendingStayMoves, 1, -1 do
        local moveBarrier = self.pendingStayMoves[i]
        if moveBarrier.done then
            table.remove(self.pendingStayMoves, i)
        elseif (now - (moveBarrier.startedAt or now)) >= 5.0 then
            moveBarrier.done = true
            table.remove(self.pendingStayMoves, i)
            self:SetStatus("Move to location " .. tostring(moveBarrier.slot or "?") .. " stopped: Stay confirmation timed out.")
        end
    end
end

function CP:SetupSecurePlacementButtons()
    if not self.API then
        self.secureReady = false
        self.secureSetupReason = "API_UNAVAILABLE"
        return false, self.secureSetupReason
    end
    local contract = self.API.GetRTSCPlacementContract and self.API:GetRTSCPlacementContract()
    self.placementContract = contract
    if type(contract) ~= "table" then
        self.secureReady = false
        self.secureSetupReason = "PLACEMENT_CONTRACT_UNAVAILABLE"
        self:RefreshSecureGrid()
        return false, self.secureSetupReason
    end

    local secureType = contract.secureType or "macro"
    local macroText = contract.macroText
    if not macroText or macroText == "" then
        self.secureReady = false
        self.secureSetupReason = "PLACEMENT_MACRO_UNAVAILABLE"
        self:RefreshSecureGrid()
        return false, self.secureSetupReason
    end

    if InCombatLockdown and InCombatLockdown() then
        self.secureReady = false
        self.secureSetupReason = "COMBAT_LOCKDOWN"
        self.pendingSecureSetup = true
        self:RefreshSecureGrid()
        return false, self.secureSetupReason
    end

    for cell = 1, 8 do
        local button = self.secureGridButtons[cell]
        if button then
            -- Keep the protected AEDM action strictly on left-click. Right-click
            -- belongs to CommandPanel's front-page context menu and must never
            -- trigger ground placement.
            button:SetAttribute("type", nil)
            button:SetAttribute("macrotext", nil)
            button:SetAttribute("type1", secureType)
            button:SetAttribute("macrotext1", macroText)
            button:SetAttribute("type2", nil)
            button:SetAttribute("macrotext2", nil)
            button:Show()
        end
    end

    self.secureReady = true
    self.secureSetupReason = nil
    self.pendingSecureSetup = false
    self:RefreshSecureGrid()
    return true
end

function CP:OnPlayerRegenEnabled()
    if self.pendingSecureSetup then self:SetupSecurePlacementButtons() end
    if self.frame then
        self:LayoutSecureGrid()
        self:RefreshSecureGrid()
    end
end

function CP:SubscribeCore()
    local function sub(eventName, fn)
        local token = self.API:Subscribe(MODULE, eventName, fn)
        self.subscriptions[#self.subscriptions + 1] = token
    end

    sub("MB_SELECTION_CHANGED", function()
        self:RefreshHeader()
        if self.workflow.mode == "recipients" or self.workflow.mode == "groups" then self:Render() end
    end)

    sub("MB_BOT_REGISTRY_READY", function()
        self:RefreshDamageSelections()
        self:ScheduleScratchPrime(0.50, "registry_ready")
        if self.workflow.mode == "recipients" then self:Render() end
        self:RefreshRTISidePanel()
    end)

    sub("MB_BOT_PRESENCE_CHANGED", function()
        self:RefreshDamageSelections()
        -- Debounce a connect-all burst into one group-level save-9 prime after
        -- newly online bots are actually present.  Never unsave the scratch
        -- slot as a presence side effect.
        self:ScheduleScratchPrime(0.75, "presence")
        if self.workflow.mode == "recipients" then self:Render() end
        self:RefreshRTISidePanel()
    end)

    sub("MB_DATA_CHANGED", function(_, domainId)
        if domainId == "BOT.STATE" or domainId == "BOT.DETAIL" or domainId == "BOT.TALENT_SPECS" or domainId == "BOT.TALENTS" then
            self:RefreshDamageSelections()
            if self.workflow.mode == "recipients" then self:Render() end
        end
    end)

    sub("MB_SESSION_CHANGED", function()
        wipeTable(self.knownSlots)
        wipeTable(self.positionHistory)
        self.flipPair = nil
        self.rtscEnableRequest = nil
        self.scratchPrimed = false
        self.scratchPrimeDueAt = nil
        self.scratchArmReadyAt = nil
        self:CancelPlacement("Session changed; tactical placement state cleared.")
        self.workflow = { mode = "front" }
        self.pendingStayMoves = {}
        self.damageSelectionsReady = false
        self.scratchCleanup = nil
        self:Render()
        self:RefreshRTISidePanel()
    end)

    sub("MB_RTI_ASSIGNMENTS_CHANGED", function()
        if self.workflow.mode == "rti_icons" then self:Render() end
        self:RefreshRTISidePanel()
    end)
end

function CP:CreateButton(parent)
    local b = CreateFrame("Button", nil, parent)
    if b.RegisterForClicks then b:RegisterForClicks("LeftButtonUp", "RightButtonUp") end
    if b.SetTemplate then b:SetTemplate("Default") end
    b:SetFrameLevel((parent:GetFrameLevel() or 0) + 10)
    b.text = b:CreateFontString(nil, "OVERLAY")
    b.text:SetPoint("CENTER")
    b.text:SetJustifyH("CENTER")
    b:SetScript("OnEnter", function(btn)
        if btn.tooltip then
            GameTooltip:SetOwner(btn, "ANCHOR_TOP")
            GameTooltip:SetText(btn.tooltip, 1, 1, 1, 1, true)
            GameTooltip:Show()
        end
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

function CP:GetButton()
    self.buttonCount = self.buttonCount + 1
    local b = self.buttonPool[self.buttonCount]
    if not b then
        b = self:CreateButton(self.frame.content)
        self.buttonPool[self.buttonCount] = b
    end
    b:Show()
    b:SetAlpha(1)
    b:Enable()
    b.tooltip = nil
    b:SetScript("OnClick", nil)
    return b
end

function CP:ReserveGridCell()
    self.buttonCount = self.buttonCount + 1
end

function CP:ResetButtons()
    self.buttonCount = 0
    -- buttonPool is intentionally sparse: secure RTSC cells reserve grid
    -- indices without creating ordinary buttons. Lua's length operator (#)
    -- is undefined for sparse arrays and can walk across a nil hole. Iterate
    -- the actual allocated buttons instead.
    for _, button in pairs(self.buttonPool) do
        if button then
            button:Hide()
            button:SetScript("OnClick", nil)
            button.tooltip = nil
        end
    end
end

function CP:AddGridButton(label, fn, tooltip, disabled)
    local b = self:GetButton()
    local db = self:GetDB()
    local cell = self.buttonCount
    local x, y, width, h = self:GetGridCellGeometry(cell)

    b:ClearAllPoints()
    SetFrameSize(b, width, h)
    b:SetPoint("TOPLEFT", self.frame.content, "TOPLEFT", x, y)
    SetUIFont(b.text, db.fontSize or 12)
    b.text:SetText(label)
    b.tooltip = tooltip
    b:SetScript("OnClick", fn)
    if disabled then
        -- Keep the normal grid cell mouse-active even when visually disabled.
        -- Secure RTSC buttons live beneath the ordinary grid; disabling this
        -- top button can allow clicks to fall through to a stale secure cell.
        b:Enable()
        b:SetScript("OnClick", nil)
        b:SetAlpha(0.35)
    end
    return b
end

function CP:SetWorkflow(mode, data)
    self.workflow = data or {}
    self.workflow.mode = mode
    self:Render()
end

function CP:GoBack()
    local w = self.workflow or {}
    if w.mode == "front" then return end
    if w.mode == "config_root" then
        self:SetWorkflow("front")
    elseif w.mode == "manage_front" then
        self:SetWorkflow("config_root", { configuring = true })
    elseif w.mode == "layout_edit" then
        self:SetWorkflow("manage_front", { configuring = true })
    elseif w.mode == "recipients" then
        self:SetWorkflow("config_root", { configuring = true })
    elseif w.mode == "groups" then
        self:SetWorkflow("recipients", { feature = w.feature, configuring = true })
    elseif w.mode == "position_actions" or w.mode == "rti_actions" or w.mode == "pull_actions" or w.mode == "formation_actions" then
        self:SetWorkflow("recipients", { feature = w.feature, configuring = true })
    elseif w.mode == "position_slots" then
        self:SetWorkflow("position_actions", { feature = "position", recipient = w.recipient, configuring = true })
    elseif w.mode == "rti_icons" then
        self:SetWorkflow("rti_actions", { feature = "targets", recipient = w.recipient, configuring = true })
    else
        self:SetWorkflow("config_root", { configuring = true })
    end
end

function CP:SummonRecipients(recipient)
    local frozen = recipient.frozen or self:FreezeTarget(recipient.spec)
    if not frozen or #frozen == 0 then
        self:SetStatus("No applicable bots for " .. tostring(recipient.label or recipient.spec) .. ".")
        return
    end

    local txId, err = self:SendTacticalOrder({
        label = recipient.label,
        spec = recipient.spec,
        frozen = frozen,
    }, "SUMMON", function(success, orderErr)
        if success then
            self:SetStatus(recipient.label .. " -> do summon.")
        else
            self:SetStatus("Summon failed: " .. tostring(orderErr or "unknown error"))
        end
    end)

    if not txId then
        self:SetStatus("Summon refused: " .. tostring(err or "unknown error"))
    end
end

function CP:ChooseRecipient(feature, def)
    local configuring = self.workflow and self.workflow.configuring == true
    if def.special == "groups" then
        self:SetWorkflow("groups", { feature = feature, configuring = configuring })
        return
    end

    local frozen = self:FreezeTarget(def.spec)
    local recipient = {
        label = def.short or def.label,
        spec = def.spec,
        frozen = frozen,
        summonMode = def.summonMode,
        summonCommand = def.summonCommand,
        movementMode = def.movementMode,
    }

    if not frozen or #frozen == 0 then
        self:SetStatus("No bots resolve for " .. def.label .. ".")
        return
    end

    if feature == "position" then
        self:EnsureRTSCEnabled()
        self:SetWorkflow("position_actions", { feature = feature, recipient = recipient, configuring = configuring })
    elseif feature == "targets" then
        self:SetWorkflow("rti_actions", { feature = feature, recipient = recipient, configuring = configuring })
    elseif feature == "pull" then
        self:SetWorkflow("pull_actions", { feature = feature, recipient = recipient, configuring = configuring })
    elseif feature == "formation" then
        self:SetWorkflow("formation_actions", { feature = feature, recipient = recipient, configuring = configuring })
    elseif feature == "summon" then
        if configuring then
            self:AddShortcut(self:MakeRecipientShortcut(recipient, "summon"))
        else
            self:SummonRecipients(recipient)
            if self:GetDB().autoReturn then self:SetWorkflow("front") end
        end
    end
end

function CP:RenderFront()
    local db = self:GetDB()
    db.frontShortcuts = self:NormalizeFrontShortcuts(db.frontShortcuts)
    self.frontSecureActions = {}
    local hasGoTo = false

    for i = 1, MAX_FRONT_SHORTCUTS do
        local shortcut = db.frontShortcuts[i]
        if shortcut then
            if shortcut.kind == "goto" or shortcut.kind == "set_location" then
                self.frontSecureActions[i] = shortcut
                if shortcut.kind == "goto" then hasGoTo = true end
                self:ReserveGridCell()
            else
                local frontIndex = i
                self:AddGridButton(self:CombatShortcutLabel(shortcut), function(_, mouseButton)
                    if mouseButton == "RightButton" then
                        self:ShowFrontContextMenu(frontIndex)
                        return
                    end
                    if mouseButton == "LeftButton" or mouseButton == nil then
                        self:ExecuteShortcut(shortcut)
                    end
                end, self:ShortcutLabel(shortcut) .. "\nRight-click: shortcut options")
            end
        else
            self:AddGridButton("EMPTY", nil, "Configure this slot in Planner mode.", true)
        end
    end

    -- Prime the reserved scratch location while the front page is merely being
    -- rendered, well before the user's later protected click.  This is what
    -- makes GO TO a reliable one-click-to-cursor control without chat/cast
    -- ordering races.
    if hasGoTo and not self.scratchPrimed and not self.scratchPrimeDueAt and not self.placement then
        self:PrimeScratchSlot("front_render")
    end
end

function CP:RenderConfigRoot()
    self:AddGridButton("POSITION", function()
        self:EnsureRTSCEnabled()
        self:SetWorkflow("recipients", { feature = "position", configuring = true })
    end, "Plan Set Location, Move To, Go To, or Clear Location shortcuts.")
    self:AddGridButton("TARGETS / RTI", function() self:SetWorkflow("recipients", { feature = "targets", configuring = true }) end,
        "Plan RTI assignment and Attack Assigned shortcuts.")
    self:AddGridButton("ORDERS / PULL", function() self:SetWorkflow("recipients", { feature = "pull", configuring = true }) end,
        "Plan Follow, Stay, Flee, Reset, Pull Assigned, and Pull Back shortcuts.")
    self:AddGridButton("FORMATION", function() self:SetWorkflow("recipients", { feature = "formation", configuring = true }) end,
        "Plan group formation shortcuts.")
    self:AddGridButton("SUMMON", function() self:SetWorkflow("recipients", { feature = "summon", configuring = true }) end,
        "Plan fast summon shortcuts.")
    self:AddGridButton("FLIP / FLOP", function() self:AddShortcut({ kind = "flipflop" }) end,
        "Add the dynamic two-group Flip/Flop command to the front page.")
    self:AddGridButton("FRONT PAGE LAYOUT", function() self:SetWorkflow("manage_front", { configuring = true }) end,
        "Review, reorder, and remove the eight combat slots.")
end

function CP:RenderManageFront()
    local shortcuts = self:GetDB().frontShortcuts
    for i = 1, MAX_FRONT_SHORTCUTS do
        local index = i
        local shortcut = shortcuts[i]
        if shortcut then
            self:AddGridButton("SLOT " .. tostring(i) .. "\n" .. self:ShortcutLabel(shortcut), function()
                self:SetWorkflow("layout_edit", { configuring = true, index = index })
            end, "Edit front-page slot " .. tostring(i) .. ".")
        else
            self:AddGridButton("SLOT " .. tostring(i) .. "\nEMPTY", nil, "New shortcuts fill the first empty slot.", true)
        end
    end
    self:AddGridButton("CLEAR FRONT PAGE", function() self:ClearFrontPage() end,
        "Remove all front-page shortcuts. This does not alter a saved preset until you press Save.", #shortcuts == 0)
end

function CP:RenderLayoutEdit(w)
    local shortcuts = self:GetDB().frontShortcuts
    local index = tonumber(w.index)
    local shortcut = index and shortcuts[index] or nil
    if not shortcut then
        self:SetWorkflow("manage_front", { configuring = true })
        return
    end

    self:AddGridButton("SLOT " .. tostring(index) .. "\n" .. self:ShortcutLabel(shortcut), nil,
        "Selected combat shortcut.", true)
    self:AddGridButton("MOVE UP", function() self:MoveShortcut(index, -1) end,
        "Move this shortcut one slot earlier.", index <= 1)
    self:AddGridButton("MOVE DOWN", function() self:MoveShortcut(index, 1) end,
        "Move this shortcut one slot later.", index >= #shortcuts)
    self:AddGridButton("REMOVE", function() self:RemoveShortcut(index) end,
        "Remove this shortcut from the front page.")
end

-- Legacy preset workflow renderers are retained only for profile/backward
-- compatibility. Alpha6 exposes presets permanently from the header instead.
function CP:RenderPresets()
    self:AddGridButton("PRESETS MOVED TO HEADER", nil, "Use the preset dropdown and Save/Save As/Delete controls above.", true)
end

function CP:RenderPresetDelete()
    self:AddGridButton("DELETE MOVED TO HEADER", nil, "Use the Delete button beside the preset selector.", true)
end


function CP:RenderRecipients(feature, groupsOnly)
    local defs = groupsOnly and self:GetGroupDefs() or self:GetRecipientDefs(feature)
    for i = 1, #defs do
        local def = defs[i]
        local countText = ""
        if not def.special then
            local frozen, count = self:ResolveRecipient(def)
            if frozen then countText = " (" .. count .. ")" end
        end
        self:AddGridButton(def.label .. countText, function() self:ChooseRecipient(feature, def) end)
    end
end

function CP:RenderPositionActions(recipient)
    local configuring = self.workflow and self.workflow.configuring == true
    self:AddGridButton("SET LOCATION", function()
        local enabled, reason = self:EnsureRTSCEnabled()
        if not enabled then self:SetStatus("RTSC enable unavailable: " .. tostring(reason or "unknown error")); return end
        self:SetWorkflow("position_slots", { feature = "position", recipient = recipient, action = "set", configuring = configuring })
    end, configuring and "Choose a location slot to add a Set Location shortcut." or "Choose one of user locations 1-8.")

    self:AddGridButton("MOVE TO", function()
        self:SetWorkflow("position_slots", { feature = "position", recipient = recipient, action = "move", configuring = configuring })
    end, configuring and "Choose a saved slot to add a Move To shortcut." or "Order this recipient set to a saved RTSC location.")

    if configuring then
        self:AddGridButton("GO TO", function()
            self:AddShortcut(self:MakeRecipientShortcut(recipient, "goto"))
        end, "Add a one-click Go To shortcut. On the front page the shortcut itself opens the AEDM world cursor.")
    else
        self:ReserveGridCell()
    end

    self:AddGridButton("CLEAR LOCATION", function()
        self:SetWorkflow("position_slots", { feature = "position", recipient = recipient, action = "clear", configuring = configuring })
    end, configuring and "Choose a slot to add a Clear Location shortcut." or "Clear one of user RTSC locations 1-8.")
end

function CP:RenderPositionSlots(w)
    local configuring = w.configuring == true
    if w.action == "set" and not configuring then
        for slot = 1, 8 do self:ReserveGridCell() end
        return
    end

    for slot = 1, 8 do
        local currentSlot = slot
        local known = self.knownSlots[slot]
        local label = "Location " .. slot .. (known and " *" or "")
        self:AddGridButton(label, function()
            if configuring then
                if w.action == "set" then
                    self:AddShortcut({ kind = "set_location", slot = currentSlot })
                elseif w.action == "move" then
                    self:AddShortcut(self:MakeRecipientShortcut(w.recipient, "move", { slot = currentSlot }))
                elseif w.action == "clear" then
                    self:AddShortcut({ kind = "clear_location", slot = currentSlot })
                end
                return
            end

            if w.action == "move" then
                self:MoveToSlot(w.recipient, currentSlot, true)
            elseif w.action == "clear" then
                local txId, err = self.API:UnsaveRTSCLocation(MODULE, currentSlot)
                if txId then
                    self.knownSlots[currentSlot] = nil
                    self:SetStatus("Clear location " .. currentSlot .. " sent (best effort).")
                    self:Render()
                else
                    self:SetStatus("Clear refused: " .. tostring(err or "unknown error"))
                end
            end
        end, known and "Session-known from this panel." or "Saved-location state is best effort.")
    end
end

function CP:RenderRTIActions(recipient)
    local configuring = self.workflow and self.workflow.configuring == true
    self:AddGridButton("PRIORITY RTI", function()
        self:SetWorkflow("rti_icons", { feature = "targets", recipient = recipient, purpose = "priority", configuring = configuring })
    end)
    self:AddGridButton("CC RTI", function()
        self:SetWorkflow("rti_icons", { feature = "targets", recipient = recipient, purpose = "cc", configuring = configuring })
    end)
    self:AddGridButton("ATTACK ASSIGNED", function()
        if configuring then self:AddShortcut(self:MakeRecipientShortcut(recipient, "rti_run", { mode = "attack" }))
        else self:RunRTI(recipient, "attack") end
    end, "Attack the recipient group's assigned priority RTI target.")
end

function CP:RenderRTIIcons(w)
    local icons = self:GetRTIIcons()
    for i = 1, #icons do
        local icon = icons[i]
        local label = type(icon) == "table" and (icon.label or icon.name or icon.id) or tostring(icon)
        local value = type(icon) == "table" and (icon.id or icon.name or icon.value) or icon
        self:AddGridButton(string.upper(tostring(label)), function()
            if w.configuring then
                self:AddShortcut(self:MakeRecipientShortcut(w.recipient, "rti_assign", { purpose = w.purpose, icon = value }))
            else
                self:AssignRTI(w.recipient, w.purpose, value)
            end
        end)
    end
end

function CP:RenderPullActions(recipient)
    local configuring = self.workflow and self.workflow.configuring == true

    local function orderButton(label, order, tooltip)
        self:AddGridButton(label, function()
            if configuring then
                self:AddShortcut(self:MakeRecipientShortcut(recipient, "order", { order = order }))
            else
                self:OrderMovement(recipient, order)
            end
        end, tooltip)
    end

    orderButton("FOLLOW", "FOLLOW", "Move toward the player, enter the current formation, and keep following.")
    orderButton("STAY", "STAY", "Stop at the current position and remain parked until another movement/order changes it.")
    orderButton("FLEE", "FLEE", "Run toward the player while Playerbots ignores normal attack/heal actions.")
    orderButton("RESET", "RESET", "Cancel the bot's current action/movement. This does not claim to restore a specific tactical state.")

    self:AddGridButton("PULL ASSIGNED", function()
        if configuring then
            self:AddShortcut(self:MakeRecipientShortcut(recipient, "rti_run", { mode = "pull" }))
        else
            self:RunPullAssigned(recipient)
        end
    end, "Release Stay for these recipients, then pull their assigned priority RTI target.")

    self:AddGridButton("PULL BACK", function()
        if configuring then self:AddShortcut(self:MakeRecipientShortcut(recipient, "combat", { command = "pull back", actionLabel = "PULL BACK" }))
        else self:ExecuteCombatCommand(recipient, "pull back", "Pull Back") end
    end, "Use the Core bridge pull-back combat semantic.")
end

function CP:RenderFormationActions(recipient)
    local configuring = self.workflow and self.workflow.configuring == true
    for i = 1, #FORMATIONS do
        local formation = FORMATIONS[i]
        self:AddGridButton(string.upper(formation), function()
            if configuring then
                self:AddShortcut(self:MakeRecipientShortcut(recipient, "formation", { formation = formation }))
                return
            end
            local ok, reason = self:Preflight("FORMATION.SET", recipient.spec, { scope = "GROUP", formation = formation })
            if not ok then self:SetStatus("Formation unavailable: " .. tostring(reason or "preflight refused")); return end
            local txId, err = self.API:Execute(MODULE, "FORMATION.SET", recipient.spec, { scope = "GROUP", formation = formation })
            if txId then self:SetStatus(recipient.label .. " formation -> " .. formation .. ".")
            else self:SetStatus("Formation refused: " .. tostring(err or "unknown error")) end
        end)
    end
end

function CP:RefreshHeader()
    if not self.frame then return end
    local count = self:GetSelectionCount()
    local bridge = self.API and self.API.IsBridgeReady and self.API:IsBridgeReady()
    self.frame.selection:SetText("Selected: " .. count .. "   Bridge: " .. (bridge and "READY" or "WAIT"))
end

function CP:Render()
    if not self.frame then return end
    -- Recover secure placement setup opportunistically whenever we render out
    -- of combat. This is idempotent and avoids a one-shot startup failure
    -- leaving protected front-page shortcuts unusable for the full session.
    if self.API and not self.secureReady and not (InCombatLockdown and InCombatLockdown()) then
        self:SetupSecurePlacementButtons()
    end
    self:ResetButtons()
    self:RefreshHeader()
    self.frontSecureActions = {}

    local w = self.workflow or { mode = "front" }
    local mode = w.mode or "front"

    local showBack = mode ~= "front" and mode ~= "config_root"
    if showBack then self.frame.back:Show() else self.frame.back:Hide() end

    -- Never reposition/resize protected secure action buttons in combat. The
    -- geometry is stable from ApplySettings/PLAYER_REGEN_ENABLED.
    if not (type(InCombatLockdown) == "function" and InCombatLockdown()) then
        self:LayoutSecureGrid()
    end

    if mode == "front" then
        self.frame.title:SetText("COMBAT CONTROL")
        self:RenderFront()
    elseif mode == "config_root" then
        self.frame.title:SetText("ENCOUNTER PLANNER")
        self:RenderConfigRoot()
    elseif mode == "manage_front" then
        self.frame.title:SetText("PLANNER > FRONT PAGE LAYOUT")
        self:RenderManageFront()
    elseif mode == "layout_edit" then
        self.frame.title:SetText("PLANNER > EDIT SLOT " .. tostring(w.index or ""))
        self:RenderLayoutEdit(w)
    elseif mode == "presets" then
        self.frame.title:SetText("PRESETS")
        self:RenderPresets()
    elseif mode == "preset_delete" then
        self.frame.title:SetText("DELETE PRESET")
        self:RenderPresetDelete()
    elseif mode == "recipients" then
        self.frame.title:SetText("PLAN: " .. string.upper(w.feature or "COMMAND") .. " > RECIPIENTS")
        self:RenderRecipients(w.feature, false)
    elseif mode == "groups" then
        self.frame.title:SetText("PLAN: " .. string.upper(w.feature or "COMMAND") .. " > RAID GROUP")
        self:RenderRecipients(w.feature, true)
    elseif mode == "position_actions" then
        self.frame.title:SetText("PLAN: POSITION > " .. w.recipient.label)
        self:RenderPositionActions(w.recipient)
    elseif mode == "position_slots" then
        self.frame.title:SetText("PLAN: POSITION > " .. w.recipient.label .. " > " .. string.upper(w.action or ""))
        self:RenderPositionSlots(w)
    elseif mode == "rti_actions" then
        self.frame.title:SetText("PLAN: TARGETS > " .. w.recipient.label)
        self:RenderRTIActions(w.recipient)
    elseif mode == "rti_icons" then
        self.frame.title:SetText("PLAN: TARGETS > " .. w.recipient.label .. " > " .. string.upper(w.purpose or "RTI"))
        self:RenderRTIIcons(w)
    elseif mode == "pull_actions" then
        self.frame.title:SetText("PLAN: CONTROL > " .. w.recipient.label)
        self:RenderPullActions(w.recipient)
    elseif mode == "formation_actions" then
        self.frame.title:SetText("PLAN: FORMATION > " .. w.recipient.label)
        self:RenderFormationActions(w.recipient)
    end

    self:RefreshHeaderControls()
    self:RefreshSecureGrid()
    self:RefreshCombatFooter()
    self:RefreshRTISidePanel()
    self:SetStatus(self.statusText)
end

function CP:GetRTIPanelRecipientDefs()
    local defs = {}
    local seen = {}

    local function add(def)
        if type(def) ~= "table" or def.special or not def.spec then return end
        local key = tostring(def.spec)
        if seen[key] then return end
        seen[key] = true
        defs[#defs + 1] = {
            label = def.short or def.label or def.spec,
            spec = def.spec,
        }
    end

    -- Keep tactical groups in the first level. Individual bots are populated
    -- separately under the Bots -> submenu so this list stays raid-readable.
    for _, def in ipairs(self:GetRecipientDefs("targets")) do add(def) end
    for _, def in ipairs(self:GetGroupDefs()) do add(def) end
    return defs
end

function CP:GetRTIPanelBotDefs()
    local defs = {}
    if not self.API or not self.API.GetBots then return defs end
    local bots = self.API:GetBots({ online = true }) or {}
    table.sort(bots, function(a, b)
        return string.lower(tostring(a.name or a.key or "")) < string.lower(tostring(b.name or b.key or ""))
    end)
    for _, bot in ipairs(bots) do
        local name = bot.name or bot.key
        if name and name ~= "" then
            defs[#defs + 1] = { label = tostring(name), spec = tostring(name) }
        end
    end
    return defs
end

function CP:PopulateRTIRecipientDropdown(level)
    if type(UIDropDownMenu_AddButton) ~= "function" then return end
    level = tonumber(level) or 1

    if level == 1 then
        local defs = self:GetRTIPanelRecipientDefs()
        for _, def in ipairs(defs) do
            local picked = { label = def.label, spec = def.spec }
            local info = UIDropDownMenu_CreateInfo and UIDropDownMenu_CreateInfo() or {}
            info.text = def.label
            info.notCheckable = true
            info.func = function()
                CP.rtiPanelRecipient = picked
                CP:RefreshRTISidePanel()
            end
            UIDropDownMenu_AddButton(info, 1)
        end

        local botsInfo = UIDropDownMenu_CreateInfo and UIDropDownMenu_CreateInfo() or {}
        botsInfo.text = "Bots"
        botsInfo.notCheckable = true
        botsInfo.hasArrow = true
        botsInfo.value = "MBCP_RTI_BOTS"
        UIDropDownMenu_AddButton(botsInfo, 1)
        return
    end

    if level == 2 and _G.UIDROPDOWNMENU_MENU_VALUE == "MBCP_RTI_BOTS" then
        local bots = self:GetRTIPanelBotDefs()
        if #bots == 0 then
            local info = UIDropDownMenu_CreateInfo and UIDropDownMenu_CreateInfo() or {}
            info.text = "No online bots"
            info.disabled = true
            info.notCheckable = true
            UIDropDownMenu_AddButton(info, 2)
            return
        end
        for _, def in ipairs(bots) do
            local picked = { label = def.label, spec = def.spec }
            local info = UIDropDownMenu_CreateInfo and UIDropDownMenu_CreateInfo() or {}
            info.text = def.label
            info.notCheckable = true
            info.func = function()
                CP.rtiPanelRecipient = picked
                CP:RefreshRTISidePanel()
            end
            UIDropDownMenu_AddButton(info, 2)
        end
    end
end

function CP:GetRTIPanelRecipient()
    local def = self.rtiPanelRecipient or { label = "All", spec = "all" }
    local frozen = self:FreezeTarget(def.spec)
    return {
        label = def.label or def.spec or "Bots",
        spec = def.spec,
        frozen = frozen,
    }
end

function CP:SetRTIPanelPurpose(purpose)
    purpose = safeLower(purpose)
    if purpose ~= "cc" then purpose = "priority" end
    self.rtiPanelPurpose = purpose
    self:RefreshRTISidePanel()
end

function CP:RefreshRTISidePanel()
    local side = self.rtiPanel
    if not side then return end
    local db = self:GetDB()
    local combatFront = self.workflow and self.workflow.mode == "front"
    if db.rtiPanelOpen and combatFront then side:Show() else side:Hide() end

    local recipient = self.rtiPanelRecipient or { label = "All", spec = "all" }
    if side.recipientDropdown and type(UIDropDownMenu_SetText) == "function" then
        UIDropDownMenu_SetText(side.recipientDropdown, recipient.label or recipient.spec or "All")
    elseif side.recipientFallback and side.recipientFallback.text then
        side.recipientFallback.text:SetText(recipient.label or recipient.spec or "All")
    end

    if side.priorityButton then side.priorityButton:SetAlpha(self.rtiPanelPurpose == "priority" and 1 or 0.45) end
    if side.ccButton then side.ccButton:SetAlpha(self.rtiPanelPurpose == "cc" and 1 or 0.45) end

    local targetName = type(UnitName) == "function" and UnitName("target") or nil
    if side.targetText then
        side.targetText:SetText(targetName and ("Target: " .. targetName) or "Target: none")
    end
end

function CP:ToggleRTISidePanel()
    local db = self:GetDB()
    db.rtiPanelOpen = not db.rtiPanelOpen
    self:RefreshRTISidePanel()
end

function CP:MarkCurrentTarget(iconIndex)
    iconIndex = tonumber(iconIndex)
    if not iconIndex or iconIndex < 1 or iconIndex > 8 then return end
    if type(UnitExists) == "function" and not UnitExists("target") then
        self:SetStatus("RTI marker: no current target.")
        return
    end
    if type(SetRaidTarget) ~= "function" then
        self:SetStatus("RTI marker API unavailable.")
        return
    end
    SetRaidTarget("target", iconIndex)
    self:SetStatus("Marked current target: " .. string.upper(RAID_ICON_BY_INDEX[iconIndex] or tostring(iconIndex)) .. ".")
    self:RefreshRTISidePanel()
end

function CP:AssignRTIFromPanel(iconName)
    local recipient = self:GetRTIPanelRecipient()
    if not recipient.frozen or #recipient.frozen == 0 then
        self:SetStatus("RTI panel: selected recipient resolves to no bots.")
        return
    end
    self:AssignRTI(recipient, self.rtiPanelPurpose or "priority", iconName)
end

function CP:RunRTIFromPanel(mode)
    local recipient = self:GetRTIPanelRecipient()
    if not recipient.frozen or #recipient.frozen == 0 then
        self:SetStatus("RTI panel: selected recipient resolves to no bots.")
        return
    end
    if string.upper(tostring(mode or "")) == "PULL" then
        self:RunPullAssigned(recipient)
    else
        self:RunRTI(recipient, mode)
    end
end

function CP:CreateRTIIconButton(parent, iconIndex, onClick)
    local b = CreateFrame("Button", nil, parent)
    SetFrameSize(b, 28, 28)
    if b.SetTemplate then b:SetTemplate("Default") end
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetPoint("TOPLEFT", b, "TOPLEFT", 3, -3)
    b.icon:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -3, 3)
    -- Core exposes the native per-icon 3.3.5 textures. Prefer those over the
    -- optional SetRaidTargetIconTexture helper so the panel always shows the
    -- actual Star/Circle/.../Skull artwork on this client.
    local iconTexture = "Interface\\TARGETINGFRAME\\UI-RaidTargetingIcon_" .. tostring(iconIndex)
    local icons = self:GetRTIIcons()
    if type(icons) == "table" then
        for _, def in ipairs(icons) do
            if type(def) == "table" and tonumber(def.id) == iconIndex and def.texture then
                iconTexture = def.texture
                break
            end
        end
    end
    b.icon:SetTexture(iconTexture)
    b.iconIndex = iconIndex
    b:SetScript("OnClick", function() if onClick then onClick(iconIndex) end end)
    b:SetScript("OnEnter", function(btn)
        if GameTooltip then
            GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
            GameTooltip:SetText(string.upper(RAID_ICON_BY_INDEX[iconIndex] or "RTI"))
            GameTooltip:Show()
        end
    end)
    b:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    return b
end

function CP:CreateRTISidePanel(parent)
    if self.rtiPanel then return self.rtiPanel end

    local side = CreateFrame("Frame", "ElvUI_Multibot_CommandPanelRTIPanel", parent)
    self.rtiPanel = side
    side:SetWidth(282)
    side:SetPoint("TOPLEFT", parent, "TOPRIGHT", 6, 0)
    side:SetPoint("BOTTOMLEFT", parent, "BOTTOMRIGHT", 6, 0)
    if side.SetTemplate then side:SetTemplate("Transparent") end
    side:SetFrameStrata("MEDIUM")
    side:SetFrameLevel((parent:GetFrameLevel() or 1) + 20)

    side.title = side:CreateFontString(nil, "OVERLAY")
    side.title:SetPoint("TOPLEFT", side, "TOPLEFT", 10, -10)
    SetUIFont(side.title, 12)
    side.title:SetText("RTI CONTROL")

    side.close = CreateHeaderButton(side, 22, "X")
    side.close:SetPoint("TOPRIGHT", side, "TOPRIGHT", -8, -7)
    side.close:SetScript("OnClick", function() CP:ToggleRTISidePanel() end)

    side.recipientCaption = side:CreateFontString(nil, "OVERLAY")
    side.recipientCaption:SetPoint("TOPLEFT", side, "TOPLEFT", 10, -38)
    SetUIFont(side.recipientCaption, 10)
    side.recipientCaption:SetText("Recipients")

    if type(UIDropDownMenu_Initialize) == "function" then
        side.recipientDropdown = CreateFrame("Frame", "ElvUI_Multibot_CommandPanelRTIRecipientDropdown", side, "UIDropDownMenuTemplate")
        side.recipientDropdown:SetPoint("TOPLEFT", side, "TOPLEFT", 58, -24)
        if type(UIDropDownMenu_SetWidth) == "function" then UIDropDownMenu_SetWidth(side.recipientDropdown, 170) end
        UIDropDownMenu_Initialize(side.recipientDropdown, function(_, level) CP:PopulateRTIRecipientDropdown(level) end)
    else
        side.recipientFallback = CreateHeaderButton(side, 180, "All")
        side.recipientFallback:SetPoint("TOPLEFT", side, "TOPLEFT", 80, -32)
    end

    side.priorityButton = CreateHeaderButton(side, 92, "PRIORITY")
    side.priorityButton:SetPoint("TOPLEFT", side, "TOPLEFT", 10, -72)
    side.priorityButton:SetScript("OnClick", function() CP:SetRTIPanelPurpose("priority") end)

    side.ccButton = CreateHeaderButton(side, 72, "CC")
    side.ccButton:SetPoint("LEFT", side.priorityButton, "RIGHT", 5, 0)
    side.ccButton:SetScript("OnClick", function() CP:SetRTIPanelPurpose("cc") end)

    side.targetText = side:CreateFontString(nil, "OVERLAY")
    side.targetText:SetPoint("TOPLEFT", side, "TOPLEFT", 10, -104)
    SetUIFont(side.targetText, 10)
    side.targetText:SetText("Target: none")

    side.markCaption = side:CreateFontString(nil, "OVERLAY")
    side.markCaption:SetPoint("TOPLEFT", side, "TOPLEFT", 10, -122)
    SetUIFont(side.markCaption, 10)
    side.markCaption:SetText("MARK CURRENT TARGET")

    side.markButtons = {}
    for i = 1, 8 do
        local b = self:CreateRTIIconButton(side, i, function(index) CP:MarkCurrentTarget(index) end)
        b:SetPoint("TOPLEFT", side, "TOPLEFT", 10 + (i - 1) * 33, -140)
        side.markButtons[i] = b
    end

    side.assignCaption = side:CreateFontString(nil, "OVERLAY")
    side.assignCaption:SetPoint("TOPLEFT", side, "TOPLEFT", 10, -180)
    SetUIFont(side.assignCaption, 10)
    side.assignCaption:SetText("ASSIGN RTI TO RECIPIENTS")

    side.assignButtons = {}
    for i = 1, 8 do
        local b = self:CreateRTIIconButton(side, i, function(index)
            CP:AssignRTIFromPanel(RAID_ICON_BY_INDEX[index])
        end)
        b:SetPoint("TOPLEFT", side, "TOPLEFT", 10 + (i - 1) * 33, -198)
        side.assignButtons[i] = b
    end

    self:RefreshRTISidePanel()
    return side
end

function CP:GetAllRecipient()
    return {
        label = "All",
        spec = "all",
        frozen = self:FreezeTarget("all"),
    }
end

function CP:ToggleAllFollowStay()
    local order = self.footerNextOrder or "FOLLOW"
    local recipient = self:GetAllRecipient()
    if not recipient.frozen or #recipient.frozen == 0 then
        self:SetStatus("No bots available for " .. string.lower(order) .. " all.")
        return
    end

    -- The emergency raid-wide footer must stay fast and deterministic. Do not
    -- gate it on 15+ individual STRATEGY.MUTATE transactions; Core 1.6.3 can
    -- issue the actual Playerbots order as one RAID/PARTY groupcall.
    local txId, err = self:SendTacticalOrder(recipient, order, function(success, orderErr)
        if success then
            CP.footerNextOrder = order == "FOLLOW" and "STAY" or "FOLLOW"
            CP:SetStatus((order == "FOLLOW" and "Follow" or "Stay") .. " All sent.")
            CP:RefreshCombatFooter()
        else
            CP:SetStatus((order == "FOLLOW" and "Follow" or "Stay") .. " All failed: " .. tostring(orderErr or "unknown error"))
        end
    end)
    if not txId then
        self:SetStatus((order == "FOLLOW" and "Follow" or "Stay") .. " All refused: " .. tostring(err or "unknown error"))
    end
end

function CP:SummonAll()
    local recipient = self:GetAllRecipient()
    if not recipient.frozen or #recipient.frozen == 0 then
        self:SetStatus("No bots available to summon.")
        return
    end
    self:SummonRecipients(recipient)
end

function CP:RefreshCombatFooter()
    if not self.frame then return end
    local front = self.workflow and self.workflow.mode == "front"
    local controls = {
        self.frame.footerFollowStay,
        self.frame.footerSummon,
        self.frame.footerRTI,
    }
    for _, control in ipairs(controls) do
        if control then
            if front then control:Show() else control:Hide() end
        end
    end

    if self.frame.footerFollowStay and self.frame.footerFollowStay.text then
        self.frame.footerFollowStay.text:SetText((self.footerNextOrder == "STAY") and "STAY ALL" or "FOLLOW ALL")
    end
    if self.frame.footerRTI and self.frame.footerRTI.text then
        self.frame.footerRTI.text:SetText(self:GetDB().rtiPanelOpen and "RTI <" or "RTI >")
    end
end

function CP:ApplySettings()
    if not self.frame then return end
    local db = self:GetDB()
    self.frame:SetScale(db.scale or 1)
    self.frame:SetAlpha(db.alpha or 1)
    SetFrameSize(self.frame, math.max(500, db.width or 500), math.max(320, db.height or 320))

    SetUIFont(self.frame.title, 13)
    SetUIFont(self.frame.selection, 10)
    SetUIFont(self.frame.back.text, 14)
    SetUIFont(self.frame.status, 10)
    if self.frame.presetCaption then SetUIFont(self.frame.presetCaption, 10) end
    self.frame.content:ClearAllPoints()
    self.frame.content:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 10, -78)
    self.frame.content:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -10, 48)
    if not (type(InCombatLockdown) == "function" and InCombatLockdown()) then
        self:LayoutSecureGrid()
    end
    if db.showStatus ~= false then self.frame.status:Show() else self.frame.status:Hide() end
    if db.enabled == false then self.frame:Hide() else self.frame:Show() end
    self:RefreshRTISidePanel()
    self:RefreshCombatFooter()
    self:Render()
end

CreateHeaderButton = function(parent, width, label)
    local b = CreateFrame("Button", nil, parent)
    SetFrameSize(b, width, 22)
    if b.SetTemplate then b:SetTemplate("Default") end
    b.text = b:CreateFontString(nil, "OVERLAY")
    b.text:SetPoint("CENTER")
    SetUIFont(b.text, 10)
    b.text:SetText(label)
    return b
end

function CP:CreateFrame()
    if self.frame then return end

    local f = CreateFrame("Frame", "ElvUI_Multibot_CommandPanelFrame", E.UIParent)
    self.frame = f

    local db = self:GetDB()
    SetFrameSize(f, math.max(500, db.width or 500), math.max(320, db.height or 320))
    f:SetPoint("CENTER", E.UIParent, "CENTER", 0, -160)
    if f.SetTemplate then f:SetTemplate("Transparent") end
    f:SetFrameStrata("MEDIUM")

    f.title = f:CreateFontString(nil, "OVERLAY")
    f.title:SetPoint("TOPLEFT", f, "TOPLEFT", 38, -10)
    SetUIFont(f.title, 13)
    f.title:SetText("COMBAT CONTROL")

    f.selection = f:CreateFontString(nil, "OVERLAY")
    f.selection:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -10)
    SetUIFont(f.selection, 10)
    f.selection:SetText("Selected: 0")

    f.back = CreateFrame("Button", nil, f)
    SetFrameSize(f.back, 24, 22)
    f.back:SetPoint("TOPLEFT", f, "TOPLEFT", 9, -7)
    if f.back.SetTemplate then f.back:SetTemplate("Default") end
    f.back.text = f.back:CreateFontString(nil, "OVERLAY")
    f.back.text:SetPoint("CENTER")
    SetUIFont(f.back.text, 14)
    f.back.text:SetText("<")
    f.back:SetScript("OnClick", function() self:GoBack() end)

    f.presetCaption = f:CreateFontString(nil, "OVERLAY")
    f.presetCaption:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -42)
    SetUIFont(f.presetCaption, 10)
    f.presetCaption:SetText("Preset")

    if type(UIDropDownMenu_Initialize) == "function" then
        f.presetDropdown = CreateFrame("Frame", "ElvUI_Multibot_CommandPanelPresetDropdown", f, "UIDropDownMenuTemplate")
        f.presetDropdown:SetPoint("TOPLEFT", f, "TOPLEFT", 38, -25)
        if type(UIDropDownMenu_SetWidth) == "function" then UIDropDownMenu_SetWidth(f.presetDropdown, 160) end
        UIDropDownMenu_Initialize(f.presetDropdown, function() CP:PopulatePresetDropdown() end)
    else
        f.presetFallback = CreateHeaderButton(f, 172, "No saved presets")
        f.presetFallback:SetPoint("TOPLEFT", f, "TOPLEFT", 54, -31)
        f.presetFallback:SetScript("OnClick", function() CP:SetStatus("Preset dropdown API unavailable on this client.") end)
    end

    f.modeButton = CreateHeaderButton(f, 68, "PLAN")
    f.modeButton:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -31)
    f.modeButton:SetScript("OnClick", function()
        if CP:IsPlannerMode() then CP:EnterCombat() else CP:EnterPlanner() end
    end)

    f.deleteButton = CreateHeaderButton(f, 58, "DELETE")
    f.deleteButton:SetPoint("RIGHT", f.modeButton, "LEFT", -4, 0)
    f.deleteButton:SetScript("OnClick", function() CP:ShowDeletePresetDialog() end)

    f.saveAsButton = CreateHeaderButton(f, 62, "SAVE AS")
    f.saveAsButton:SetPoint("RIGHT", f.deleteButton, "LEFT", -4, 0)
    f.saveAsButton:SetScript("OnClick", function() CP:ShowPresetDialog(true) end)

    f.saveButton = CreateHeaderButton(f, 50, "SAVE")
    f.saveButton:SetPoint("RIGHT", f.saveAsButton, "LEFT", -4, 0)
    f.saveButton:SetScript("OnClick", function()
        local active = CP:GetDB().activePreset
        if active and CP:GetDB().presets[active] then
            CP:SavePreset(active)
        else
            CP:ShowPresetDialog(true)
        end
    end)

    f.content = CreateFrame("Frame", nil, f)
    f.content:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -78)
    f.content:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 48)

    f.footerFollowStay = CreateHeaderButton(f, 92, "FOLLOW ALL")
    f.footerFollowStay:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10, 28)
    f.footerFollowStay:SetScript("OnClick", function() CP:ToggleAllFollowStay() end)
    f.footerFollowStay:SetScript("OnEnter", function(btn)
        if GameTooltip then
            GameTooltip:SetOwner(btn, "ANCHOR_TOP")
            GameTooltip:SetText("Follow / Stay All")
            GameTooltip:AddLine("One-click toggle. Uses raid chat in a raid and party chat in a party.", 1, 1, 1, true)
            GameTooltip:Show()
        end
    end)
    f.footerFollowStay:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

    f.footerSummon = CreateHeaderButton(f, 92, "SUMMON ALL")
    f.footerSummon:SetPoint("LEFT", f.footerFollowStay, "RIGHT", 5, 0)
    f.footerSummon:SetScript("OnClick", function() CP:SummonAll() end)

    f.footerRTI = CreateHeaderButton(f, 58, "RTI >")
    f.footerRTI:SetPoint("LEFT", f.footerSummon, "RIGHT", 5, 0)
    f.footerRTI:SetScript("OnClick", function() CP:ToggleRTISidePanel() end)

    f.status = f:CreateFontString(nil, "OVERLAY")
    f.status:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10, 11)
    f.status:SetPoint("RIGHT", f, "RIGHT", -10, 0)
    f.status:SetJustifyH("LEFT")
    SetUIFont(f.status, 10)
    f.status:SetText("Initializing...")

    self:CreateSecureGrid()
    self:CreateRTISidePanel(f)
    f:SetScript("OnUpdate", function(_, elapsed) self:OnPlacementUpdate(elapsed) end)

    E:CreateMover(f, "MultibotCommandPanelMover", "Multibot CommandPanel", nil, nil, nil, "ALL,GENERAL")
    self:ApplySettings()
end

function CP:OnPlayerEnteringWorld()
    -- ElvUI's final media/mover initialization is complete by this point.
    self:ApplySettings()
    -- Secure attributes occasionally cannot be finalized during the plugin
    -- initialization pass on the 3.3.5 client. Retry once the player has
    -- actually entered the world instead of leaving GO TO/SET LOCATION blank
    -- for the entire session.
    if self.API and not self.secureReady and not (InCombatLockdown and InCombatLockdown()) then
        self:SetupSecurePlacementButtons()
    end
    self:ScheduleScratchPrime(0.75, "entering_world")
    self:RefreshRTISidePanel()
    self:Render()
end

function CP:OnPlayerTargetChanged()
    self:RefreshRTISidePanel()
end

function CP:InitializeCore()
    local Core = _G.ElvUI_Multibot_Core
    if not Core or not Core.GetAPI then
        self:SetStatus("ElvUI_Multibot_Core API unavailable.")
        return false
    end

    local API, err = Core:GetAPI(1)
    if not API then
        self:SetStatus("Core API v1 unavailable: " .. tostring(err or "unknown error"))
        return false
    end

    -- Bind the public API immediately after version negotiation.  This keeps
    -- diagnostics/recipient resolution truthful even if a required optional
    -- CommandPanel service is absent from the installed Core build.
    self.Core = Core
    self.API = API

    if type(API.OrderBots) ~= "function" or type(API.ArmRTSCLocationImmediate) ~= "function" then
        self:SetStatus("Core tactical extensions unavailable; install lifecycle-corrected Core 1.6.5.")
        return false
    end

    local ok, registerErr = API:RegisterModule(MODULE, {
        version = VERSION,
        description = "Dynamic raid command workflow panel",
    })
    if ok == false then
        self:SetStatus("Core module registration failed: " .. tostring(registerErr or "unknown error"))
        return false
    end

    self:SubscribeCore()
    return true
end

function CP:Initialize()
    if self.initialized then return true end

    -- ElvUI 6.09 creates E.data/E.db inside E:Initialize(). CommandPanel owns
    -- profile-backed UI and must not bind or construct it before that point.
    if not E or type(E.data) ~= "table" or type(E.db) ~= "table" then
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

    self:CreateFrame()

    if not self:InitializeCore() then
        if self.frame then self.frame:Show() end
        return false, "CORE_NOT_READY"
    end

    self:RegisterEvent("PLAYER_REGEN_ENABLED", "OnPlayerRegenEnabled")
    self:RegisterEvent("PLAYER_ENTERING_WORLD", "OnPlayerEnteringWorld")
    self:RegisterEvent("PLAYER_TARGET_CHANGED", "OnPlayerTargetChanged")

    self:SetupSecurePlacementButtons()
    self:RefreshDamageSelections()
    self:SetStatus("Ready. Combat page active; choose a preset above or press PLAN to prepare an encounter.")
    self:Render()
    self.initialized = true
    return true
end

function CP:Shutdown()
    if self.API and self.API.UnregisterModule then
        self.API:UnregisterModule(MODULE)
    end
    self.API = nil
    self.Core = nil
    self.subscriptions = {}
    self.initialized = false
    if self.frame then self.frame:Hide() end
end

SLASH_ELVUIMULTIBOTCOMMANDPANEL1 = "/mbcp"
SlashCmdList.ELVUIMULTIBOTCOMMANDPANEL = function(msg)
    msg = safeLower(msg or "")
    if msg == "resetpair" then
        wipeTable(CP.positionHistory)
        CP.flipPair = nil
        CP:SetStatus("Flip/Flop history cleared.")
        CP:Render()
    elseif msg == "status" then
        local mover = _G.MultibotCommandPanelMover
        CP:Print(
            "version=" .. VERSION ..
            " initialized=" .. tostring(CP.initialized) ..
            " frame=" .. tostring(CP.frame ~= nil) ..
            " mover=" .. tostring(mover ~= nil) ..
            " core=" .. tostring(CP.API and CP.API:GetCoreVersion() or "nil") ..
            " selected=" .. CP:GetSelectionCount() ..
            " secureRTSC=" .. tostring(CP.secureReady) ..
            " secureReason=" .. tostring(CP.secureSetupReason or "ready") ..
            " scratch9=" .. (CP.scratchPrimed and "READY" or (CP.scratchArmReadyAt and "ARMING" or "NO")) ..
            " flip=" .. tostring(CP.flipPair ~= nil) ..
            " shortcuts=" .. tostring(#CP:GetDB().frontShortcuts) ..
            " presets=" .. tostring(#CP:GetPresetNames()) ..
            " preset=" .. tostring(CP:GetDB().activePreset or "custom") ..
            " dirty=" .. tostring(CP:GetDB().presetDirty == true) ..
            " mode=" .. tostring(CP.workflow and CP.workflow.mode or "nil")
        )
    else
        if not CP.frame then
            CP:Print("panel frame is not initialized; use /mbcp status for diagnostics")
            return
        end
        if CP.frame:IsShown() then CP.frame:Hide() else CP.frame:Show() end
    end
end

-- Runtime lifecycle is registered from Options.lua after options methods exist.
