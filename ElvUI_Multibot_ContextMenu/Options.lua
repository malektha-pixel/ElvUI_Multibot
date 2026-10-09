local addonName = ...
local ContextMenu = _G.ElvUI_Multibot_ContextMenu
if not ContextMenu then return end

local E
if type(ElvUI) == "table" and type(unpack) == "function" then
    E = select(1, unpack(ElvUI))
end

local function refresh()
    if ContextMenu.RefreshVisibleMenuPresentation then ContextMenu:RefreshVisibleMenuPresentation() end
end

function ContextMenu:InsertOptions()
    E = E or self.E
    if not E or not E.Options or not E.Options.args then return end
    self:InitializeSettings()

    E.Options.args.multibotContextMenu = {
        type = "group",
        name = "Multibot Context Menu",
        order = 93,
        childGroups = "tab",
        args = {
            appearance = {
                type = "group",
                name = "Appearance",
                order = 1,
                args = {
                    intro = {
                        type = "description",
                        order = 1,
                        name = "Controls the appearance of Multibot context menus. Empty-world PRIMARY menus and explicit per-bot menus can be scaled independently; text and background settings remain shared.",
                    },
                    worldScale = {
                        type = "range",
                        order = 10,
                        name = "World menu scale",
                        desc = "Scale the PRIMARY/selection menu opened by Shift+Right-clicking empty 3D world. Includes its submenus and RTSC placement rows.",
                        min = 0.65,
                        max = 1.75,
                        step = 0.05,
                        isPercent = true,
                        get = function() return ContextMenu:GetSettings().worldScale end,
                        set = function(_, value)
                            ContextMenu:GetSettings().worldScale = value
                            refresh()
                        end,
                    },
                    unitFrameScale = {
                        type = "range",
                        order = 11,
                        name = "UnitFrame menu scale",
                        desc = "Scale explicit per-bot menus opened from bot UnitFrames and, when enabled, hovered Playerbots in the 3D world. Includes their submenus.",
                        min = 0.65,
                        max = 1.75,
                        step = 0.05,
                        isPercent = true,
                        get = function() return ContextMenu:GetSettings().unitFrameScale end,
                        set = function(_, value)
                            ContextMenu:GetSettings().unitFrameScale = value
                            refresh()
                        end,
                    },
                    textSize = {
                        type = "range",
                        order = 12,
                        name = "Text size",
                        desc = "Set the font size used by entries in the Multibot context menu.",
                        min = 8,
                        max = 18,
                        step = 1,
                        get = function() return ContextMenu:GetSettings().textSize end,
                        set = function(_, value)
                            ContextMenu:GetSettings().textSize = value
                            refresh()
                        end,
                    },
                    backgroundColor = {
                        type = "color",
                        order = 20,
                        name = "Background color",
                        desc = "Choose the background color used by the Multibot context menu and its submenus.",
                        hasAlpha = false,
                        get = function()
                            local color = ContextMenu:GetSettings().backgroundColor
                            return color.r, color.g, color.b
                        end,
                        set = function(_, r, g, b)
                            local color = ContextMenu:GetSettings().backgroundColor
                            color.r, color.g, color.b = r, g, b
                            refresh()
                        end,
                    },
                    transparency = {
                        type = "range",
                        order = 21,
                        name = "Background transparency",
                        desc = "Set how transparent the menu background is. 0% is fully opaque; 100% is fully transparent. Text is not affected.",
                        min = 0,
                        max = 100,
                        step = 1,
                        get = function() return ContextMenu:GetSettings().backgroundTransparency end,
                        set = function(_, value)
                            ContextMenu:GetSettings().backgroundTransparency = value
                            refresh()
                        end,
                    },
                },
            },
            interaction = {
                type = "group",
                name = "Interaction",
                order = 2,
                args = {
                    intro = {
                        type = "description",
                        order = 1,
                        name = "Interaction timing only affects the Multibot context menu. Other ElvUI and Blizzard dropdown menus are not changed.",
                    },
                    worldBotMode = {
                        type = "select",
                        order = 10,
                        name = "World Playerbot menu",
                        desc = "Choose whether Shift+Right-clicking a Playerbot in the 3D world opens the same explicit per-bot menu as its UnitFrame. PRIMARY is ignored for this menu. The out-of-combat mode uses WoW's native combat-lockdown state, not an ElvUI combat flag.",
                        values = {
                            [1] = "Disabled",
                            [2] = "Enabled",
                            [3] = "Enabled out of combat",
                        },
                        get = function()
                            local mode = ContextMenu:GetWorldBotMode()
                            if mode == "DISABLED" then return 1 end
                            if mode == "ENABLED" then return 2 end
                            return 3
                        end,
                        set = function(_, value)
                            local mode = value == 1 and "DISABLED" or (value == 2 and "ENABLED" or "OUT_OF_COMBAT")
                            ContextMenu:GetSettings().worldBotMode = mode
                            if mode == "DISABLED" or (mode == "OUT_OF_COMBAT" and InCombatLockdown and InCombatLockdown()) then
                                local kind = ContextMenu.activeMenu and ContextMenu.activeMenu.entry and ContextMenu.activeMenu.entry.context and ContextMenu.activeMenu.entry.context.contextKind
                                if kind == "WORLD_BOT" then
                                    if type(HideDropDownMenu) == "function" then HideDropDownMenu(1) end
                                    ContextMenu.activeMenu = nil
                                    if ContextMenu.HideRTSCSecureOverlays then ContextMenu:HideRTSCSecureOverlays() end
                                    if ContextMenu.ReleaseStrategyInterest then ContextMenu:ReleaseStrategyInterest() end
                                end
                            end
                            refresh()
                        end,
                    },
                    grace = {
                        type = "range",
                        order = 20,
                        name = "Hover-out grace period",
                        desc = "Seconds the menu remains available after the pointer leaves it. Moving back over the menu before this expires cancels the close countdown.",
                        min = 0,
                        max = 5,
                        step = 0.10,
                        get = function() return ContextMenu:GetSettings().hoverGrace end,
                        set = function(_, value)
                            ContextMenu:GetSettings().hoverGrace = value
                            refresh()
                        end,
                    },
                },
            },
        },
    }
end

function ContextMenu:RegisterOptionsPlugin()
    if self.optionsPluginRegistered then return true end
    local EP = LibStub and LibStub("LibElvUIPlugin-1.0", true)
    if not EP then return false, "LIB_ELVUI_PLUGIN_UNAVAILABLE" end

    EP:RegisterPlugin(addonName, function() ContextMenu:InsertOptions() end)
    self.optionsPluginRegistered = true
    return true
end
-- Register lifecycle only after this final addon file has defined the options
-- registration method. This preserves both normal startup and unusual late/manual
-- loading after ElvUI has already completed E:Initialize().
local LifecycleEP = LibStub and LibStub("LibElvUIPlugin-1.0", true)
if E and E.data and E.db then
    ContextMenu:Initialize() -- late/manual load after ElvUI is already initialized
elseif LifecycleEP and type(LifecycleEP.HookInitialize) == "function" then
    LifecycleEP:HookInitialize(ContextMenu, "Initialize")
else
    error("ElvUI_Multibot_ContextMenu requires ElvUI 6.09 with LibElvUIPlugin-1.0")
end

