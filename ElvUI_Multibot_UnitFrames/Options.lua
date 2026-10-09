local ADDON_NAME = ...

local ElvUI = _G.ElvUI
if not ElvUI then return end

local E = unpack(ElvUI)
local EP = LibStub and LibStub("LibElvUIPlugin-1.0", true)

local ANCHORS = {
    TOPLEFT = "Top Left",
    TOP = "Top",
    TOPRIGHT = "Top Right",
    LEFT = "Left",
    CENTER = "Center",
    RIGHT = "Right",
    BOTTOMLEFT = "Bottom Left",
    BOTTOM = "Bottom",
    BOTTOMRIGHT = "Bottom Right",
}

local function GetModule()
    return E:GetModule("MultibotUnitFrames", true)
end

local function BuildTextGroup(MBUF, key, name, order, description)
    return {
        type = "group",
        name = name,
        order = order,
        inline = true,
        args = {
            description = {
                type = "description",
                order = 1,
                name = description,
            },
            show = {
                type = "toggle",
                order = 10,
                name = "Show " .. name,
                get = function()
                    return MBUF:GetDB()[key].enabled == true
                end,
                set = function(_, value)
                    MBUF:GetDB()[key].enabled = value == true
                    MBUF:ApplyPresentationSettings()
                end,
            },
            fontSize = {
                type = "range",
                order = 20,
                name = "Font size",
                min = 7,
                max = 20,
                step = 1,
                get = function()
                    return tonumber(MBUF:GetDB()[key].fontSize) or 9
                end,
                set = function(_, value)
                    MBUF:GetDB()[key].fontSize = value
                    MBUF:ApplyPresentationSettings()
                end,
            },
            anchor = {
                type = "select",
                order = 30,
                name = "Anchor point",
                values = ANCHORS,
                get = function()
                    return tostring(MBUF:GetDB()[key].anchor or "CENTER")
                end,
                set = function(_, value)
                    MBUF:GetDB()[key].anchor = tostring(value or "CENTER")
                    MBUF:ApplyPresentationSettings()
                end,
            },
            x = {
                type = "range",
                order = 40,
                name = "X offset",
                min = -100,
                max = 100,
                step = 1,
                get = function()
                    return tonumber(MBUF:GetDB()[key].x) or 0
                end,
                set = function(_, value)
                    MBUF:GetDB()[key].x = value
                    MBUF:ApplyPresentationSettings()
                end,
            },
            y = {
                type = "range",
                order = 41,
                name = "Y offset",
                min = -100,
                max = 100,
                step = 1,
                get = function()
                    return tonumber(MBUF:GetDB()[key].y) or 0
                end,
                set = function(_, value)
                    MBUF:GetDB()[key].y = value
                    MBUF:ApplyPresentationSettings()
                end,
            },
        },
    }
end

local function BuildIndicatorGroup(MBUF)
    return {
        type = "group",
        name = "PB Indicator",
        order = 1,
        inline = true,
        args = {
            description = {
                type = "description",
                order = 1,
                name = "Marks unit frames belonging to online playerbots.",
            },
            show = {
                type = "toggle",
                order = 10,
                name = "Show PB indicator",
                get = function()
                    return MBUF:GetDB().indicator.enabled == true
                end,
                set = function(_, value)
                    MBUF:GetDB().indicator.enabled = value == true
                    MBUF:ApplyPresentationSettings()
                end,
            },
            text = {
                type = "input",
                order = 20,
                name = "Indicator text",
                get = function()
                    return tostring(MBUF:GetDB().indicator.text or "PB")
                end,
                set = function(_, value)
                    value = tostring(value or "")
                    if value == "" then value = "PB" end
                    MBUF:GetDB().indicator.text = value
                    MBUF:ApplyPresentationSettings()
                end,
            },
            fontSize = {
                type = "range",
                order = 30,
                name = "Font size",
                min = 7,
                max = 20,
                step = 1,
                get = function()
                    return tonumber(MBUF:GetDB().indicator.fontSize) or 10
                end,
                set = function(_, value)
                    MBUF:GetDB().indicator.fontSize = value
                    MBUF:ApplyPresentationSettings()
                end,
            },
            anchor = {
                type = "select",
                order = 35,
                name = "Anchor point",
                desc = "Choose which point of the unit frame the indicator is anchored to.",
                values = ANCHORS,
                get = function()
                    return tostring(MBUF:GetDB().indicator.anchor or "TOPRIGHT")
                end,
                set = function(_, value)
                    MBUF:GetDB().indicator.anchor = tostring(value or "TOPRIGHT")
                    MBUF:ApplyPresentationSettings()
                end,
            },
            x = {
                type = "range",
                order = 40,
                name = "X offset",
                min = -100,
                max = 100,
                step = 1,
                get = function()
                    return tonumber(MBUF:GetDB().indicator.x) or -2
                end,
                set = function(_, value)
                    MBUF:GetDB().indicator.x = value
                    MBUF:ApplyPresentationSettings()
                end,
            },
            y = {
                type = "range",
                order = 41,
                name = "Y offset",
                min = -100,
                max = 100,
                step = 1,
                get = function()
                    return tonumber(MBUF:GetDB().indicator.y) or -2
                end,
                set = function(_, value)
                    MBUF:GetDB().indicator.y = value
                    MBUF:ApplyPresentationSettings()
                end,
            },
        },
    }
end

local function BuildInventoryGroup(MBUF)
    local group = BuildTextGroup(
        MBUF,
        "inventoryText",
        "Inventory",
        2,
        "Displays bag-slot usage as Bag: <percent> or Bag: <used>/<total>."
    )
    group.args.mode = {
        type = "select",
        order = 25,
        name = "Display mode",
        values = {
            PERCENT = "Percent used",
            USED_TOTAL = "Used / total slots",
        },
        get = function()
            return tostring(MBUF:GetDB().inventoryText.mode or "PERCENT")
        end,
        set = function(_, value)
            MBUF:GetDB().inventoryText.mode = tostring(value or "PERCENT")
            MBUF:ApplyPresentationSettings()
        end,
    }
    return group
end

local function BuildCurrencyGroup(MBUF)
    local group = BuildTextGroup(
        MBUF,
        "currencyText",
        "Currency",
        4,
        "Displays bot money. Gold is always shown; silver and copper can be included or hidden independently."
    )
    group.args.showSilver = {
        type = "toggle",
        order = 25,
        name = "Show silver",
        get = function()
            return MBUF:GetDB().currencyText.showSilver == true
        end,
        set = function(_, value)
            MBUF:GetDB().currencyText.showSilver = value == true
            MBUF:ApplyPresentationSettings()
        end,
    }
    group.args.showCopper = {
        type = "toggle",
        order = 26,
        name = "Show copper",
        get = function()
            return MBUF:GetDB().currencyText.showCopper == true
        end,
        set = function(_, value)
            MBUF:GetDB().currencyText.showCopper = value == true
            MBUF:ApplyPresentationSettings()
        end,
    }
    return group
end


local function BuildQuestGroup(MBUF)
    local group = BuildTextGroup(
        MBUF,
        "questText",
        "Quest Log",
        5,
        "Displays current quest-log occupancy as Quest: <current>/<maximum>."
    )
    group.args.colorByCapacity = {
        type = "toggle",
        order = 25,
        name = "Color by fullness",
        desc = "Fade from white when nearly empty, through yellow around halfway, to red as the quest log fills.",
        get = function()
            return MBUF:GetDB().questText.colorByCapacity == true
        end,
        set = function(_, value)
            MBUF:GetDB().questText.colorByCapacity = value == true
            MBUF:ApplyPresentationSettings()
        end,
    }
    return group
end

local function BuildSelectionGroup(MBUF)
    return {
        type = "group",
        name = "Selection",
        order = 3,
        args = {
            intro = {
                type = "description",
                order = 1,
                name = "Ctrl + left-click a bot unit frame to toggle it in the shared PRIMARY selection. Ctrl + left-click empty world space clears the selection. These gestures do not change your normal player target.",
            },
            clickEnabled = {
                type = "toggle",
                order = 10,
                name = "Enable Ctrl-click selection",
                get = function()
                    return MBUF:GetDB().selection.clickEnabled == true
                end,
                set = function(_, value)
                    MBUF:SetSelectionClickEnabled(value)
                end,
            },
            highlightEnabled = {
                type = "toggle",
                order = 20,
                name = "Show selected border",
                get = function()
                    return MBUF:GetDB().selection.highlightEnabled == true
                end,
                set = function(_, value)
                    MBUF:GetDB().selection.highlightEnabled = value == true
                    MBUF:ApplyPresentationSettings()
                end,
            },
            borderSize = {
                type = "range",
                order = 30,
                name = "Border size",
                min = 1,
                max = 6,
                step = 1,
                get = function()
                    return tonumber(MBUF:GetDB().selection.borderSize) or 2
                end,
                set = function(_, value)
                    MBUF:GetDB().selection.borderSize = value
                    MBUF:ApplyPresentationSettings()
                end,
            },
            color = {
                type = "color",
                order = 40,
                name = "Border color",
                hasAlpha = true,
                get = function()
                    local color = MBUF:GetDB().selection.color or {}
                    return tonumber(color.r) or 0.20, tonumber(color.g) or 0.80, tonumber(color.b) or 1.00, tonumber(color.a) or 1.00
                end,
                set = function(_, r, g, b, a)
                    local settings = MBUF:GetDB().selection
                    settings.color = settings.color or {}
                    settings.color.r = r
                    settings.color.g = g
                    settings.color.b = b
                    settings.color.a = a or 1
                    MBUF:ApplyPresentationSettings()
                end,
            },
            clear = {
                type = "execute",
                order = 50,
                name = "Clear selection now",
                desc = "Clear the shared PRIMARY bot selection.",
                func = function()
                    MBUF.api:ClearSelection("PRIMARY")
                end,
            },
        },
    }
end

local function InsertOptions()
    if not E.Options or not E.Options.args then return end

    local MBUF = GetModule()
    if not MBUF then return end

    E.Options.args.multibotUnitFrames = {
        type = "group",
        name = "Multibot UnitFrames",
        order = 93,
        childGroups = "tab",
        args = {
            general = {
                type = "group",
                name = "General",
                order = 1,
                args = {
                    intro = {
                        type = "description",
                        order = 1,
                        name = "Bot-aware presentation on ElvUI party and raid frames using ElvUI_Multibot_Core 1.0. Gameplay actions are not part of this alpha.",
                    },
                    enabled = {
                        type = "toggle",
                        order = 10,
                        name = "Enable UnitFrames module",
                        get = function()
                            return MBUF:GetDB().enabled == true
                        end,
                        set = function(_, value)
                            MBUF:SetModuleEnabled(value)
                        end,
                    },
                    reset = {
                        type = "execute",
                        order = 90,
                        name = "Reset module settings",
                        desc = "Reset Multibot UnitFrames settings in the current ElvUI profile to their defaults.",
                        func = function()
                            MBUF:ResetSettings()
                        end,
                    },
                },
            },
            statusPanel = {
                type = "group",
                name = "Status Panel",
                order = 2,
                childGroups = "tab",
                args = {
                    intro = {
                        type = "description",
                        order = 0,
                        name = "Configure the lightweight bot status shown on ElvUI party and raid frames. Each element keeps its own visibility, anchor, font size, and offsets.",
                    },
                    stateStrategies = {
                        type = "group",
                        name = "State & Strategies",
                        order = 1,
                        args = {
                            intro = {
                                type = "description",
                                order = 0,
                                name = "Bot identity, movement state, role, and specialization.",
                            },
                            indicator = BuildIndicatorGroup(MBUF),
                            movementText = BuildTextGroup(
                                MBUF,
                                "movementText",
                                "Movement State",
                                2,
                                "Shows Following, Staying, Fleeing, or Unknown."
                            ),
                            roleText = BuildTextGroup(
                                MBUF,
                                "roleText",
                                "Role",
                                3,
                                "Shows the bot's current role."
                            ),
                            specText = BuildTextGroup(
                                MBUF,
                                "specText",
                                "Spec",
                                4,
                                "Shows the bot's current specialization."
                            ),
                        },
                    },
                    characterStats = {
                        type = "group",
                        name = "Character Stats",
                        order = 2,
                        args = {
                            intro = {
                                type = "description",
                                order = 0,
                                name = "XP, bag usage, durability, currency, and quest-log occupancy.",
                            },
                            xpText = BuildTextGroup(
                                MBUF,
                                "xpText",
                                "XP",
                                1,
                                "Displays the bot's experience as XP: <percent>."
                            ),
                            inventoryText = BuildInventoryGroup(MBUF),
                            durabilityText = BuildTextGroup(
                                MBUF,
                                "durabilityText",
                                "Durability",
                                3,
                                "Displays durability as Dura: <percent>."
                            ),
                            currencyText = BuildCurrencyGroup(MBUF),
                            questText = BuildQuestGroup(MBUF),
                        },
                    },
                },
            },
            selection = BuildSelectionGroup(MBUF),
        },
    }
end

local MBUF = GetModule()

function MBUF:RegisterOptions()
    if self.optionsRegistered then return true end

    if not EP then return false end

    EP:RegisterPlugin(ADDON_NAME, InsertOptions)
    self.optionsRegistered = true
    return true
end

-- External ElvUI plugins must enter runtime only after ElvUI has completed its
-- own initialization and AceDB profile construction. LibElvUIPlugin provides that
-- lifecycle hook; do not use the internal ElvUI module-registration path here.
if EP and EP.HookInitialize then
    EP:HookInitialize(MBUF, "Initialize")
end
