local _, MB = ...

local function joinSortedKeys(tableValue)
    local keys = MB:SortedKeys(tableValue)
    return #keys > 0 and table.concat(keys, ", ") or "none"
end

function MB:StatusText()
    local connected = (self.bridge.connected and self.bridge.handshakeReady) and "ready" or (self.bridge.connected and "handshaking" or "disconnected")
    return string.format(
        "Core %s | API %d | Bridge %s | protocol %s | server %s | identity %s | bots %d | modules %d | pending reads %d | actions %d",
        tostring(self.version), tonumber(self.API_VERSION) or 0, connected, tostring(self.bridge.protocol or "n/a"),
        tostring(self.bridge.server or "n/a"), (self.botRegistryReady and self.botRegistryReadyEpoch == self.sessionEpoch) and "ready" or "pending", #self:GetBots(), self:TableCount(self.modules),
        self:TableCount(self.pendingReads), self:TableCount(self.bridge.actionTokens)
    )
end

function MB:PrintStatus() self:Print(self:StatusText()) end
function MB:PrintCapabilities() self:Print("Bridge capabilities: " .. joinSortedKeys(self.bridge.capabilities)) end

function MB:PrintModules()
    local names = self:SortedKeys(self.modules)
    self:Print("Registered modules (" .. tostring(#names) .. "): " .. (#names > 0 and table.concat(names, ", ") or "none"))
end

function MB:PrintSelections()
    local ids = self:SortedKeys(self.selections)
    if #ids == 0 then self:Print("Working selections: none") end
    for _, id in ipairs(ids) do
        local s = self:GetSelection(id)
        local names = {}; for _, bot in ipairs(s.bots) do names[#names + 1] = bot.name end
        self:Print("Working selection " .. id .. ": " .. (#names > 0 and table.concat(names, ", ") or "empty"))
    end
    local saved = self.GetSavedSelections and self:GetSavedSelections() or {}
    if #saved == 0 then self:Print("Saved selections: none"); return end
    for _, s in ipairs(saved) do
        local names = {}; for _, bot in ipairs(s.bots or {}) do names[#names + 1] = bot.name end
        local source = s.sourceKind == "SELECTOR" and ("dynamic=" .. tostring(type(s.source) == "string" and s.source or "selector")) or "static"
        self:Print("Saved selection " .. tostring(s.name) .. " (" .. source .. "): " .. (#names > 0 and table.concat(names, ", ") or "empty"))
    end
end

function MB:PrintPendingReads()
    if next(self.pendingReads) == nil then self:Print("Pending reads: none"); return end
    for _, request in pairs(self.pendingReads) do
        self:Print(string.format("%s %s %s token=%s", request.id, request.domainId, request.targetKey, tostring(request.token or "-")))
    end
end

function MB:PrintObservedExtensions()
    local keys = self:SortedKeys(self.bridge.observedExtensions)
    if #keys == 0 then self:Print("Observed unknown protocol extensions: none"); return end
    for _, opcode in ipairs(keys) do
        local e = self.bridge.observedExtensions[opcode]
        self:Print(string.format("Observed %s x%d sample=%s", opcode, tonumber(e.count) or 0, tostring(e.sample or "")))
    end
end

function MB:PrintManifest()
    local manifest = self.API:GetManifest()
    self:Print("Manifest: Core " .. tostring(manifest.coreVersion) .. " / API " .. tostring(manifest.apiVersion))
    self:Print("Domains: " .. table.concat(manifest.domains, ", "))
    self:Print("Actions: " .. table.concat(manifest.actions, ", "))
    self:Print("Capabilities: " .. joinSortedKeys(manifest.bridgeCapabilities))
end


local function parseDiagnosticTarget(domainId, rest)
    local parts = MB:Split(MB:Trim(rest), " ", false)
    local descriptor = MB.dataDomains[domainId]
    if not descriptor then return nil, "UNKNOWN_DOMAIN" end
    if descriptor.scope == "GLOBAL" then return "GLOBAL" end
    if descriptor.scope == "BOT_VARIANT" then
        local variant = tonumber(parts[2]) or parts[2]
        if not parts[1] or not variant then return nil, "Usage: /mbcore read " .. domainId .. " <bot> <variant>" end
        return { bot = parts[1], [descriptor.variantField or "variant"] = variant }
    end
    if not parts[1] then return nil, "Usage: /mbcore read " .. domainId .. " <bot>" end
    return parts[1]
end

function MB:DiagnosticRead(rest)
    local domainId, targetRest = self:SplitOnce(self:Trim(rest), " ")
    domainId = self:Upper(domainId)
    local target, err = parseDiagnosticTarget(domainId, targetRest)
    if not target then self:Print(err); return end
    local id, readErr = self:RefreshDomain(domainId, target, function(value, meta)
        if value then MB:Print(string.format("Read %s complete: target=%s revision=%s", domainId, tostring(meta and meta.targetKey or "?"), tostring(meta and meta.revision or "?")))
        else MB:Print("Read " .. domainId .. " failed: " .. tostring(meta and meta.error or "unknown")) end
    end)
    self:Print(id and ("Read requested: " .. tostring(id)) or ("Read failed: " .. tostring(readErr)))
end

function MB:DiagnosticGet(rest)
    local domainId, targetRest = self:SplitOnce(self:Trim(rest), " ")
    domainId = self:Upper(domainId)
    local target, err = parseDiagnosticTarget(domainId, targetRest)
    if not target then self:Print(err); return end
    local value, meta = self:GetData(domainId, target)
    if not value then self:Print("Cache miss: " .. domainId .. " (" .. tostring(meta and meta.error or meta and meta.status or "missing") .. ")"); return end
    local count = type(value.items) == "table" and #value.items or (type(value.spellIds) == "table" and #value.spellIds or nil)
    self:Print(string.format("Cache %s target=%s revision=%s stale=%s%s", domainId, tostring(meta.targetKey), tostring(meta.revision), tostring(meta.stale == true), count and (" items=" .. tostring(count)) or ""))
end

function MB:HandleSlash(input)
    local command, rest = self:SplitOnce(self:Trim(input), " ")
    command = self:Lower(command)
    if command == "" or command == "status" then self:PrintStatus()
    elseif command == "hello" then self:BridgeHello()
    elseif command == "refresh" then self:RefreshActiveData()
    elseif command == "caps" then self:PrintCapabilities()
    elseif command == "modules" then self:PrintModules()
    elseif command == "selections" then self:PrintSelections()
    elseif command == "requests" then self:PrintPendingReads()
    elseif command == "extensions" then self:PrintObservedExtensions()
    elseif command == "manifest" then self:PrintManifest()
    elseif command == "read" then self:DiagnosticRead(rest)
    elseif command == "get" then self:DiagnosticGet(rest)
    elseif command == "debug" then
        local value = self:Lower(rest)
        if value == "on" then self.db.diagnostics.debug = true
        elseif value == "off" then self.db.diagnostics.debug = false
        else self.db.diagnostics.debug = not self.db.diagnostics.debug end
        self:Print("Debug " .. (self.db.diagnostics.debug and "enabled" or "disabled"))
    elseif command == "options" then
        if self.E and self.E.ToggleOptionsUI then self.E:ToggleOptionsUI() else self:Print("Open ElvUI options and select Multibot Core.") end
    else
        self:Print("Commands: status, hello, refresh, caps, modules, selections, requests, extensions, manifest, read <domain> [bot] [variant], get <domain> [bot] [variant], debug [on|off], options")
    end
end
