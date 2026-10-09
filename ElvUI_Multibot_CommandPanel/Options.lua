local ADDON = ...

local ElvUI = _G.ElvUI
if not ElvUI then return end
local E, L, V, P, G = unpack(ElvUI)
if not E then return end

local CP = E:GetModule("MultibotCommandPanel", true)
if not CP then return end


local function DB()
    return CP:GetDB()
end

local function Get(key)
    local db = DB()
    if not db then return nil end
    return db[key]
end

local function Set(key, value)
    local db = DB()
    if not db then return end
    db[key] = value
    CP:ApplySettings()
end

function CP:InsertOptions()
    if not E or not E.Options or not E.Options.args then return end
    self:InitializeSettings()
    E.Options.args.multibotCommandPanel = {
        order = 100,
        type = "group",
        name = "Multibot CommandPanel",
        childGroups = "tab",
        args = {
            general = {
                order = 1,
                type = "group",
                name = "General",
                args = {
                    enabled = {
                        order = 1,
                        type = "toggle",
                        name = "Enable",
                        desc = "Show the permanent raid command panel.",
                        get = function() return Get("enabled") end,
                        set = function(_, value) Set("enabled", value) end,
                    },
                    showStatus = {
                        order = 2,
                        type = "toggle",
                        name = "Show status line",
                        desc = "Show concise Core dispatch / RTSC workflow feedback.",
                        get = function() return Get("showStatus") end,
                        set = function(_, value) Set("showStatus", value) end,
                    },
                    resetPair = {
                        order = 10,
                        type = "execute",
                        name = "Clear Flip/Flop pair",
                        desc = "Clear only CommandPanel's transient two-group position history.",
                        func = function()
                            for k in pairs(CP.positionHistory) do CP.positionHistory[k] = nil end
                            CP.flipPair = nil
                            CP:SetStatus("Flip/Flop history cleared.")
                            CP:Render()
                        end,
                    },
                },
            },
            appearance = {
                order = 2,
                type = "group",
                name = "Appearance",
                args = {
                    width = {
                        order = 1,
                        type = "range",
                        name = "Width",
                        min = 500, max = 760, step = 1,
                        get = function() return Get("width") end,
                        set = function(_, value) Set("width", value) end,
                    },
                    height = {
                        order = 2,
                        type = "range",
                        name = "Height",
                        min = 320, max = 520, step = 1,
                        get = function() return Get("height") end,
                        set = function(_, value) Set("height", value) end,
                    },
                    scale = {
                        order = 3,
                        type = "range",
                        name = "Scale",
                        min = 0.65, max = 1.5, step = 0.01,
                        get = function() return Get("scale") end,
                        set = function(_, value) Set("scale", value) end,
                    },
                    alpha = {
                        order = 4,
                        type = "range",
                        name = "Opacity",
                        min = 0.25, max = 1.0, step = 0.01,
                        get = function() return Get("alpha") end,
                        set = function(_, value) Set("alpha", value) end,
                    },
                    buttonHeight = {
                        order = 5,
                        type = "range",
                        name = "Planner button height",
                        min = 20, max = 40, step = 1,
                        get = function() return Get("buttonHeight") end,
                        set = function(_, value) Set("buttonHeight", value) end,
                    },
                    frontButtonHeight = {
                        order = 6,
                        type = "range",
                        name = "Combat button height",
                        desc = "Height of the eight quick-reaction buttons on the combat front page.",
                        min = 32, max = 58, step = 1,
                        get = function() return Get("frontButtonHeight") end,
                        set = function(_, value) Set("frontButtonHeight", value) end,
                    },
                    spacing = {
                        order = 7,
                        type = "range",
                        name = "Button spacing",
                        min = 1, max = 10, step = 1,
                        get = function() return Get("spacing") end,
                        set = function(_, value) Set("spacing", value) end,
                    },
                    fontSize = {
                        order = 8,
                        type = "range",
                        name = "Button text size",
                        min = 8, max = 18, step = 1,
                        get = function() return Get("fontSize") end,
                        set = function(_, value) Set("fontSize", value) end,
                    },
                },
            },
        },
    }
end

function CP:RegisterOptionsPlugin()
    if self.optionsPluginRegistered then return true end
    local plugin = LibStub and LibStub("LibElvUIPlugin-1.0", true)
    if not plugin then return false, "LIB_ELVUI_PLUGIN_UNAVAILABLE" end

    plugin:RegisterPlugin(ADDON or "ElvUI_Multibot_CommandPanel", function() CP:InsertOptions() end)
    self.optionsPluginRegistered = true
    return true
end

-- Follow the corrected ElvUI 6.09 lifecycle used by Core and the validated
-- Multibot modules. Normal startup binds after E:Initialize(); unusual late or
-- manual loading may initialize immediately only when E.data/E.db already exist.
local LifecycleEP = LibStub and LibStub("LibElvUIPlugin-1.0", true)
if E and E.data and E.db then
    CP:Initialize()
elseif LifecycleEP and type(LifecycleEP.HookInitialize) == "function" then
    LifecycleEP:HookInitialize(CP, "Initialize")
else
    error("ElvUI_Multibot_CommandPanel requires ElvUI 6.09 with LibElvUIPlugin-1.0")
end
