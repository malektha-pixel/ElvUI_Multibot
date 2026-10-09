local addonName, MB = ...

local function ensureRoot()
    if not MB.E or not MB.E.Options or not MB.E.Options.args then return nil end
    MB.E.Options.args.multibotCore = MB.E.Options.args.multibotCore or {
        type = "group", name = "Multibot Core", order = 92, childGroups = "tab", args = {},
    }
    return MB.E.Options.args.multibotCore
end

local function registeredModulesText()
    local names = MB:SortedKeys(MB.modules)
    if #names == 0 then return "No external Multibot modules are currently registered." end
    return "Registered modules:\n• " .. table.concat(names, "\n• ")
end

local function extensionsText()
    local keys = MB:SortedKeys(MB.bridge.observedExtensions)
    if #keys == 0 then return "No unknown bridge protocol extensions have been observed." end
    local out = { "Observed protocol extensions:" }
    for _, opcode in ipairs(keys) do
        local e = MB.bridge.observedExtensions[opcode]
        out[#out + 1] = string.format("• %s (%d)", opcode, tonumber(e.count) or 0)
    end
    return table.concat(out, "\n")
end

function MB:InsertOptions()
    local root = ensureRoot()
    if not root then return end
    root.args = {
        general = {
            type = "group", name = "General", order = 1,
            args = {
                status = { type = "description", order = 1, name = function() return MB:StatusText() end },
                boundary = {
                    type = "description", order = 2,
                    name = "Multibot Core provides shared bot data and communication for other ElvUI Multibot modules. Most gameplay controls and display settings are configured in those modules.",
                },
                enabled = {
                    type = "toggle", order = 10, name = "Enable Core",
                    desc = "Enable the Multibot Core backend. Disabling it stops Core processing and resets the current bridge session until the Core is enabled again.",
                    get = function() return MB.db.enabled == true end,
                    set = function(_, value)
                        MB.db.enabled = value == true
                        if MB.db.enabled then MB:StartBridgeSession("OPTIONS_ENABLE") else MB:ResetBridgeSession("CORE_DISABLED") end
                    end,
                },
                bridge = {
                    type = "toggle", order = 11, name = "Enable bridge communication",
                    desc = "Allow the Core to communicate with mod-multibot-bridge. Disable this only when you intentionally want the Core loaded without a live bridge connection.",
                    get = function() return MB.db.bridge.enabled == true end,
                    set = function(_, value)
                        MB.db.bridge.enabled = value == true
                        if value then MB:StartBridgeSession("OPTIONS_BRIDGE_ENABLE") else MB:ResetBridgeSession("BRIDGE_DISABLED") end
                    end,
                },
                refresh = {
                    type = "execute", order = 20, name = "Refresh active data",
                    desc = "Request an immediate refresh of the Core's main shared bot data and any data currently being used by registered modules.",
                    func = function() MB:RefreshActiveData() end,
                },
                hello = {
                    type = "execute", order = 21, name = "Retry bridge handshake",
                    desc = "Send a new bridge HELLO message. Useful for manually retrying the connection handshake after the server or bridge has restarted.",
                    func = function() MB:BridgeHello() end,
                },
                printStatus = {
                    type = "execute", order = 22, name = "Print Core status",
                    desc = "Print the current Core, bridge, bot-registry and request status to the chat window for troubleshooting.",
                    func = function() MB:PrintStatus() end,
                },
                suppressNoise = {
                    type = "toggle", order = 30, name = "Hide automatic bot replies",
                    desc = "Hide recognized bot replies caused by Core-owned automatic workflows, such as background inventory reads during a trade. The Core still receives and processes these messages. Direct or unrelated bot whispers are not hidden by this setting.",
                    get = function() return MB.db.chat.suppressAutomaticNoise == true end,
                    set = function(_, value)
                        MB.db.chat.suppressAutomaticNoise = value == true
                        if not value and MB.ClearWhisperPresentationSuppression then MB:ClearWhisperPresentationSuppression(nil, nil, "OPTION_DISABLED") end
                    end,
                },
            },
        },
        data = {
            type = "group", name = "Shared Data", order = 2,
            args = {
                intro = {
                    type = "description", order = 1,
                    name = "These intervals control how often shared data is refreshed while a module is actively using it. Lower values update sooner but create more bridge traffic. A module may request a faster interval when needed.",
                },
                roster = {
                    type = "range", order = 10, name = "Roster refresh",
                    desc = "Seconds between refreshes of the shared live bot roster. This controls how quickly general bot presence changes are picked up while the roster is in use.",
                    min = 2, max = 30, step = 1,
                    get = function() return MB.db.updates.roster end,
                    set = function(_, v) MB.db.updates.roster = v end,
                },
                state = {
                    type = "range", order = 11, name = "Strategy state refresh",
                    desc = "Seconds between refreshes of each bot's combat and non-combat Playerbots strategy state while that data is in use.",
                    min = 2, max = 60, step = 1,
                    get = function() return MB.db.updates.state end,
                    set = function(_, v) MB.db.updates.state = v end,
                },
                detail = {
                    type = "range", order = 12, name = "Bot details refresh",
                    desc = "Seconds between refreshes of general bot details such as race, class, level, talent points and gear score while that data is in use.",
                    min = 5, max = 120, step = 5,
                    get = function() return MB.db.updates.detail end,
                    set = function(_, v) MB.db.updates.detail = v end,
                },
                stats = {
                    type = "range", order = 13, name = "Bot stats refresh",
                    desc = "Seconds between refreshes of summary stats such as money, bag usage, durability, XP and mana while that data is in use.",
                    min = 5, max = 120, step = 5,
                    get = function() return MB.db.updates.stats end,
                    set = function(_, v) MB.db.updates.stats = v end,
                },
                inventory = {
                    type = "range", order = 14, name = "Inventory refresh",
                    desc = "Seconds between structured inventory refreshes while a module has requested inventory data. Inventory is not continuously polled when no module is using it.",
                    min = 10, max = 180, step = 5,
                    get = function() return MB.db.updates.inventory end,
                    set = function(_, v) MB.db.updates.inventory = v end,
                },
                note = {
                    type = "description", order = 30,
                    name = "Other heavier data sources are requested only when needed rather than continuously refreshed. Exact physical bag/slot positions are used only when the bridge provides authoritative slot data.",
                },
            },
        },
        modules = {
            type = "group", name = "Modules", order = 3,
            args = {
                summary = { type = "description", order = 1, name = registeredModulesText },
                explanation = {
                    type = "description", order = 2,
                    name = "Registered modules use the Core for shared data, services and contextual bot actions. Their player-facing controls and settings remain separate from the Core.",
                },
            },
        },
        bridge = {
            type = "group", name = "Bridge", order = 4,
            args = {
                intro = {
                    type = "description", order = 1,
                    name = "Bridge connection timing. The defaults are recommended unless you are troubleshooting connection behavior.",
                },
                caps = {
                    type = "description", order = 2,
                    name = function()
                        local caps = table.concat(MB:SortedKeys(MB.bridge.capabilities), ", ")
                        return "Server capabilities: " .. (caps ~= "" and caps or "none detected")
                    end,
                },
                heartbeat = {
                    type = "range", order = 10, name = "Heartbeat interval",
                    desc = "Seconds between bridge heartbeat pings while connected. Lower values check the connection more often and create slightly more addon traffic.",
                    min = 5, max = 60, step = 1,
                    get = function() return MB.db.bridge.heartbeatInterval end,
                    set = function(_, v) MB.db.bridge.heartbeatInterval = v end,
                },
                retry = {
                    type = "range", order = 11, name = "Handshake retry interval",
                    desc = "Seconds between connection-handshake retries while the bridge has not completed startup. Lower values retry more aggressively.",
                    min = 2, max = 30, step = 1,
                    get = function() return MB.db.bridge.handshakeRetryInterval end,
                    set = function(_, v) MB.db.bridge.handshakeRetryInterval = v end,
                },
                timeout = {
                    type = "range", order = 12, name = "Disconnect timeout",
                    desc = "Seconds without receiving bridge traffic before the Core treats the connection as stale and starts a new bridge session.",
                    min = 15, max = 120, step = 5,
                    get = function() return MB.db.bridge.disconnectTimeout end,
                    set = function(_, v) MB.db.bridge.disconnectTimeout = v end,
                },
                requestTimeout = {
                    type = "range", order = 13, name = "Data request timeout",
                    desc = "Seconds the Core waits for a bridge data read to complete before marking that request as timed out.",
                    min = 3, max = 30, step = 1,
                    get = function() return MB.db.bridge.requestTimeout end,
                    set = function(_, v) MB.db.bridge.requestTimeout = v end,
                },
            },
        },
        developer = {
            type = "group", name = "Developer", order = 5,
            args = {
                intro = {
                    type = "description", order = 1,
                    name = "Diagnostics for addon development and troubleshooting. These options are not required for normal gameplay.",
                },
                debug = {
                    type = "toggle", order = 2, name = "Debug logging to chat",
                    desc = "Print additional Core diagnostic messages to the chat window. Leave this disabled during normal use unless you are investigating a problem.",
                    get = function() return MB.db.diagnostics.debug == true end,
                    set = function(_, v) MB.db.diagnostics.debug = v == true end,
                },
                unknown = { type = "description", order = 10, name = extensionsText },
                printCaps = {
                    type = "execute", order = 20, name = "Print bridge capabilities",
                    desc = "Print the bridge capabilities currently known to the Core.",
                    func = function() MB:PrintCapabilities() end,
                },
                printModules = {
                    type = "execute", order = 21, name = "Print registered modules",
                    desc = "Print the Multibot modules currently registered with the Core.",
                    func = function() MB:PrintModules() end,
                },
                printRequests = {
                    type = "execute", order = 22, name = "Print pending data requests",
                    desc = "Print bridge data reads that are currently waiting for a response.",
                    func = function() MB:PrintPendingReads() end,
                },
                printManifest = {
                    type = "execute", order = 23, name = "Print API manifest",
                    desc = "Print the Core API version and the currently registered data domains, actions and bridge capabilities.",
                    func = function() MB:PrintManifest() end,
                },
                clearCache = {
                    type = "execute", order = 30, name = "Clear Core cache",
                    desc = "Clear the Core's current in-memory data cache. Active modules can request fresh data again afterwards. This does not delete saved module configuration.",
                    confirm = "Clear the current Core data cache?",
                    func = function() MB:ClearCache() end,
                },
            },
        },
    }
end

function MB:RegisterElvUIOptionsPlugin()
    if self.optionsPluginRegistered then return true end
    local EP = LibStub and LibStub("LibElvUIPlugin-1.0", true)
    if not EP then return false, "LIB_ELVUI_PLUGIN_UNAVAILABLE" end

    EP:RegisterPlugin(addonName, function() MB:InsertOptions() end)
    self.optionsPluginRegistered = true
    return true
end
