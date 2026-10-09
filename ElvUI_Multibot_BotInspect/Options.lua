local addonName = ...
local BotInspect = _G.ElvUI_Multibot_BotInspect
if not BotInspect then return end

local E
if type(ElvUI) == "table" and type(unpack) == "function" then E = select(1, unpack(ElvUI)) end

function BotInspect:InsertOptions()
    E = E or self.E
    if not E or not E.Options or not E.Options.args then return end
    if type(self.ExtendElvUIMicroBarOptionLimit) == "function" then self:ExtendElvUIMicroBarOptionLimit() end
    self:InitializeSettings()
    E.Options.args.multibotBotInspect = {
        type = "group", name = "Multibot BotInspect", order = 94, childGroups = "tab",
        args = {
            appearance = {
                type = "group", name = "Appearance", order = 1,
                args = {
                    intro = { type = "description", order = 1, name = "BotInspect integrates Gear & Inventory plus a Spellbook view, a virtualized managed/live bot roster, and optional master-loot recipient inspection. Spellbook supports retained offline display, manual bot spell casts, autonomous-use controls, and drag-to-action-bar macros through Core; offline inspection remains read-only." },
                    scale = {
                        type = "range", order = 10, name = "Window scale", min = 0.70, max = 1.50, step = 0.05, isPercent = true,
                        get = function() return BotInspect:GetSettings().scale end,
                        set = function(_, value) BotInspect:GetSettings().scale = value; BotInspect:ApplySettings() end,
                    },
                    itemSize = {
                        type = "range", order = 20, name = "Inventory slot size", min = 26, max = 38, step = 1,
                        get = function() return BotInspect:GetSettings().itemSize end,
                        set = function(_, value) BotInspect:GetSettings().itemSize = value; BotInspect:ApplySettings() end,
                    },
                    columns = {
                        type = "range", order = 21, name = "Inventory columns", min = 8, max = 11, step = 1,
                        get = function() return BotInspect:GetSettings().inventoryColumns end,
                        set = function(_, value) BotInspect:GetSettings().inventoryColumns = value; BotInspect:ApplySettings() end,
                    },
                    roster = {
                        type = "toggle", order = 22, name = "Roster expanded by default",
                        get = function() return BotInspect:GetSettings().rosterExpanded ~= false end,
                        set = function(_, value) BotInspect:GetSettings().rosterExpanded = value and true or false; BotInspect:ApplyRosterExpanded() end,
                    },
                    microbar = {
                        type = "toggle", order = 23, name = "Show ElvUI Micro Bar button",
                        desc = "Add a BotInspect launcher to ElvUI 6.09's Micro Bar. It follows the Micro Bar mover, rows, visibility, alpha and mouseover settings.",
                        get = function() return BotInspect:GetSettings().showMicroBarButton ~= false end,
                        set = function(_, value)
                            BotInspect:GetSettings().showMicroBarButton = value and true or false
                            if type(BotInspect.RefreshMicroBarButton) == "function" then BotInspect:RefreshMicroBarButton() end
                        end,
                    },
                    hotkeyEnabled = {
                        type = "toggle", order = 24, name = "Enable BotInspect shortcut",
                        desc = "Give BotInspect its own temporary override shortcut. While enabled, this exact key combination takes precedence over the normal WoW binding without rewriting your saved key bindings. Default: Shift+C.",
                        get = function() return BotInspect:GetSettings().hotkeyEnabled ~= false end,
                        set = function(_, value)
                            if type(BotInspect.SetHotkeyEnabled) == "function" then BotInspect:SetHotkeyEnabled(value)
                            else BotInspect:GetSettings().hotkeyEnabled = value and true or false end
                        end,
                    },
                    hotkey = {
                        type = "keybinding", order = 25, name = "BotInspect shortcut",
                        desc = "Press a key combination to toggle BotInspect. Plain C remains the normal Character panel unless you deliberately assign C here. Changes made during combat apply when combat ends.",
                        disabled = function() return BotInspect:GetSettings().hotkeyEnabled == false end,
                        get = function() return BotInspect:GetSettings().hotkey or "SHIFT-C" end,
                        set = function(_, value)
                            if type(BotInspect.SetHotkey) == "function" then BotInspect:SetHotkey(value)
                            else BotInspect:GetSettings().hotkey = value end
                        end,
                    },
                    resetPosition = {
                        type = "execute", order = 30, name = "Reset window position",
                        func = function()
                            local db = BotInspect:GetSettings(); db.point, db.relativePoint, db.x, db.y = "CENTER", "CENTER", 0, 0; BotInspect:ApplyPosition()
                        end,
                    },
                },
            },
            masterLoot = {
                type = "group", name = "Master Loot", order = 2,
                args = {
                    intro = { type = "description", order = 1, name = "Enhance ElvUI 6.09's master-loot flow without replacing its loot-assignment behavior. BotInspect tracks the selected ElvUI loot slot and decorates the recipient dropdown with class color, spec, role and Gear Score; hover a bot to see a compact loot-vs-equipped comparison. In raids, a Send to self shortcut is inserted before the Group entries." },
                    enabled = {
                        type = "toggle", order = 10, name = "Enable master-loot enhancements",
                        get = function() return BotInspect:GetSettings().masterLootEnhancements ~= false end,
                        set = function(_, value) BotInspect:GetSettings().masterLootEnhancements = value and true or false end,
                    },
                },
            },
        },
    }
end

function BotInspect:RegisterOptionsPlugin()
    if self.optionsPluginRegistered then return true end
    local EP = LibStub and LibStub("LibElvUIPlugin-1.0", true)
    if not EP then return false end
    EP:RegisterPlugin(addonName, function() BotInspect:InsertOptions() end)
    self.optionsPluginRegistered = true
    return true
end
