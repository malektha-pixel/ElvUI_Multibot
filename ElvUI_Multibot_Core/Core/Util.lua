local _, MB = ...

local floor = math.floor
local lower = string.lower
local upper = string.upper
local sub = string.sub
local find = string.find
local gsub = string.gsub
local format = string.format

function MB:Now()
    if type(GetTime) == "function" then return GetTime() end
    return time and time() or 0
end

function MB:Trim(value)
    if value == nil then return "" end
    return (tostring(value):gsub("^%s+", ""):gsub("%s+$", ""))
end

function MB:Upper(value) return upper(self:Trim(value)) end
function MB:Lower(value) return lower(self:Trim(value)) end

function MB:NormalizeName(value)
    local name = self:Trim(value)
    if name == "" then return nil end
    local dash = find(name, "-", 1, true)
    if dash and dash > 1 then name = sub(name, 1, dash - 1) end
    return name
end

function MB:BotKey(value)
    local name = self:NormalizeName(value)
    return name and lower(name) or nil
end

function MB:Copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local out = {}
    seen[value] = out
    for k, v in pairs(value) do out[self:Copy(k, seen)] = self:Copy(v, seen) end
    return out
end

function MB:Merge(destination, source)
    if type(destination) ~= "table" then destination = {} end
    if type(source) ~= "table" then return destination end
    for k, v in pairs(source) do
        if type(v) == "table" then
            destination[k] = self:Merge(type(destination[k]) == "table" and destination[k] or {}, v)
        else
            destination[k] = v
        end
    end
    return destination
end

function MB:DeepEqual(a, b, seen)
    if a == b then return true end
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return false end
    seen = seen or {}
    if seen[a] == b then return true end
    seen[a] = b
    for k, v in pairs(a) do
        if not self:DeepEqual(v, b[k], seen) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

function MB:SplitOnce(value, separator)
    value = tostring(value or "")
    separator = separator or "~"
    local at = find(value, separator, 1, true)
    if not at then return value, "" end
    return sub(value, 1, at - 1), sub(value, at + #separator)
end

function MB:Split(value, separator, includeEmpty)
    value = tostring(value or "")
    separator = separator or "~"
    local out, startAt = {}, 1
    while true do
        local at = find(value, separator, startAt, true)
        local piece
        if at then piece = sub(value, startAt, at - 1) else piece = sub(value, startAt) end
        if includeEmpty or piece ~= "" then out[#out + 1] = piece end
        if not at then break end
        startAt = at + #separator
    end
    return out
end

function MB:EncodeField(value)
    local s = tostring(value or "")
    return (gsub(s, "[%%~\r\n]", function(char)
        return format("%%%02X", string.byte(char))
    end))
end

function MB:DecodeField(value)
    local s = tostring(value or "")
    return (gsub(s, "%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16) or 0)
    end))
end

function MB:ToNumber(value, default)
    local n = tonumber(value)
    if n == nil then return default or 0 end
    return n
end

function MB:ToBoolean(value)
    if value == true or value == 1 then return true end
    local s = lower(self:Trim(value))
    return s == "1" or s == "true" or s == "yes" or s == "on"
end

function MB:TableCount(value)
    local n = 0
    if type(value) == "table" then for _ in pairs(value) do n = n + 1 end end
    return n
end

function MB:SortedKeys(value)
    local out = {}
    if type(value) == "table" then for k in pairs(value) do out[#out + 1] = k end end
    table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
    return out
end

function MB:NewToken(tag)
    self.sequence = (self.sequence or 0) + 1
    local millis = floor(self:Now() * 1000)
    return tostring(millis) .. "-mbc-" .. tostring(tag or "t") .. "-" .. tostring(self.sequence)
end

function MB:After(delay, callback)
    if type(callback) ~= "function" then return nil end
    self.timerSequence = (self.timerSequence or 0) + 1
    local token = "timer-" .. tostring(self.timerSequence)
    self.timers[token] = { at = self:Now() + math.max(0, tonumber(delay) or 0), callback = callback }
    return token
end

function MB:CancelTimer(token)
    if token then self.timers[token] = nil end
end

function MB:RunTimers()
    local now = self:Now()
    local due = {}
    for token, entry in pairs(self.timers) do
        if entry.at <= now then due[#due + 1] = token end
    end
    for _, token in ipairs(due) do
        local entry = self.timers[token]
        self.timers[token] = nil
        if entry and type(entry.callback) == "function" then
            local ok, err = pcall(entry.callback)
            if not ok then self:Log("ERROR", "Timer failed: " .. tostring(err)) end
        end
    end
end

function MB:Log(level, message, ...)
    level = upper(self:Trim(level ~= nil and level or "INFO"))
    local text
    if select("#", ...) > 0 then
        local ok, rendered = pcall(format, tostring(message or ""), ...)
        text = ok and rendered or tostring(message or "")
    else
        text = tostring(message or "")
    end
    local entry = { time = self:Now(), level = level, text = text }
    local log = self.runtime and self.runtime.log
    if type(log) == "table" then
        log[#log + 1] = entry
        local maxEntries = self.db and self.db.diagnostics and tonumber(self.db.diagnostics.maxLogEntries) or 180
        while #log > maxEntries do table.remove(log, 1) end
    end
    if self.db and self.db.diagnostics and self.db.diagnostics.debug and DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff1784d1MBC|r [" .. level .. "] " .. text)
    end
end

function MB:Print(message)
    if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cff1784d1ElvUI Multibot Core:|r " .. tostring(message or "")) end
end

function MB:SafeCall(callback, ...)
    if type(callback) ~= "function" then return true end
    local ok, a, b, c, d = pcall(callback, ...)
    if not ok then
        self:Log("ERROR", "Callback failed: " .. tostring(a))
        return false, a
    end
    return true, a, b, c, d
end

function MB:NormalizeScope(scope, defaultScope)
    scope = upper(self:Trim(scope ~= nil and scope or defaultScope or "BOT"))
    return scope
end

function MB:ExtractItemLink(rawLine)
    rawLine = tostring(rawLine or "")
    -- Playerbots inventory lines normally end in "|r" followed by an optional xN count.
    -- Preserve the exact server-provided hyperlink (including enchant/gem/random-property fields)
    -- rather than regenerating a lossy item:<id> link from the client cache.
    local colored = string.match(rawLine, "(|c%x%x%x%x%x%x%x%x|Hitem:[^|]+|h%[[^%]]*%]|h|r)")
    if colored and colored ~= "" then return colored end
    local plain = string.match(rawLine, "(|Hitem:[^|]+|h%[[^%]]*%]|h)")
    return plain
end

function MB:ExtractItemId(value)
    if type(value) == "number" then return value > 0 and math.floor(value) or nil end
    if type(value) == "table" then
        local id = tonumber(value.itemId or value.id)
        if id and id > 0 then return math.floor(id) end
        value = value.serverLink or value.link or value.rawLine or value.itemString
    end
    local text = tostring(value or "")
    local numeric = tonumber(text)
    if numeric and numeric > 0 then return math.floor(numeric) end
    local id = tonumber(string.match(text, "item:(%d+)"))
    return id and id > 0 and id or nil
end

function MB:ExtractItemLinkName(link)
    link = tostring(link or "")
    local name = string.match(link, "|h%[([^%]]*)%]|h")
    return name and name ~= "" and name or nil
end

function MB:EnrichInventoryItem(item)
    local out = self:Copy(item or {})
    local itemId = tonumber(out.itemId) or 0
    local metadataResolved = false
    if itemId > 0 and type(GetItemInfo) == "function" then
        local name, clientLink, quality, itemLevel, requiredLevel, itemType, itemSubType, stackCount, equipLoc, icon = GetItemInfo(itemId)
        if name or clientLink or itemType or icon then metadataResolved = true end
        out.clientLink = clientLink or out.clientLink
        out.name = name or out.name or self:ExtractItemLinkName(out.serverLink)
        out.quality = quality ~= nil and quality or out.quality
        out.itemLevel = itemLevel ~= nil and itemLevel or out.itemLevel
        out.requiredLevel = requiredLevel ~= nil and requiredLevel or out.requiredLevel
        out.type = itemType or out.type
        out.subType = itemSubType or out.subType
        out.stackSize = stackCount ~= nil and stackCount or out.stackSize
        out.equipLoc = equipLoc or out.equipLoc
        out.icon = icon or out.icon
    end
    if not out.icon and itemId > 0 and type(GetItemIcon) == "function" then out.icon = GetItemIcon(itemId) end
    out.serverLink = out.serverLink or self:ExtractItemLink(out.rawLine)
    out.link = out.serverLink or out.clientLink or out.link
    out.name = out.name or self:ExtractItemLinkName(out.link) or (itemId > 0 and ("Item " .. tostring(itemId)) or "Unknown item")
    out.metadataResolved = metadataResolved or out.metadataResolved == true
    out.equipCandidate = type(out.equipLoc) == "string" and out.equipLoc ~= ""
    out.actionAddressable = itemId > 0
    out.exactStackAddressable = out.locationKnown == true and out.bag ~= nil and out.slot ~= nil
    out.identity = {
        itemId = itemId,
        addressKind = "ITEM_ID",
        exactStack = out.exactStackAddressable == true,
        serverLink = out.serverLink,
    }
    return out
end

function MB:ParseItemLine(rawLine, source)
    rawLine = tostring(rawLine or "")
    local serverLink = self:ExtractItemLink(rawLine)
    local itemId = self:ExtractItemId(serverLink or rawLine) or 0
    local count = 1
    local parts = self:Split(rawLine, "|", true)
    if parts[6] then
        local parsed = tonumber(string.match(parts[6], "^rx(%d+)"))
        if parsed and parsed > 0 then count = parsed end
    end
    if count == 1 then
        local parsed = tonumber(string.match(rawLine, "|rx(%d+)"))
        if parsed and parsed > 0 then count = parsed end
    end

    local item = {
        itemId = itemId,
        count = count,
        rawLine = rawLine,
        serverLink = serverLink,
        link = serverLink,
        name = self:ExtractItemLinkName(serverLink),
        locationKnown = false,
        bag = nil,
        slot = nil,
        equipmentSlot = nil,
        equipped = nil,
        location = { known = false },
        source = source or "BRIDGE.INVENTORY",
    }
    return self:EnrichInventoryItem(item)
end

function MB:AggregateItems(items)
    local byId = {}
    for _, item in ipairs(items or {}) do
        local id = tonumber(item.itemId) or 0
        if id > 0 then
            local entry = byId[id]
            if not entry then
                entry = { itemId = id, count = 0, records = {} }
                byId[id] = entry
            end
            entry.count = entry.count + (tonumber(item.count) or 1)
            entry.records[#entry.records + 1] = item
        end
    end
    return byId
end
