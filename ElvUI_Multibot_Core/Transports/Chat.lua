local _, MB = ...

MB.chat = MB.chat or { lastSendAt = 0 }

local function canChat(self)
    if not self.db or not self.db.chat or not self.db.chat.enabled then return false, "CHAT_DISABLED" end
    if type(SendChatMessage) ~= "function" then return false, "SEND_CHAT_UNAVAILABLE" end
    return true
end

local function markSent(self)
    self.chat.lastSendAt = self:Now()
    self.runtime.counters.chatTx = self.runtime.counters.chatTx + 1
end

function MB:ChatGroupChannel()
    local raidCount = type(GetNumRaidMembers) == "function" and (GetNumRaidMembers() or 0) or 0
    if raidCount > 0 then return "RAID" end
    local partyCount = type(GetNumPartyMembers) == "function" and (GetNumPartyMembers() or 0) or 0
    if partyCount > 0 then return "PARTY" end
    return nil
end

-- Intentionally internal. Consumer modules never receive an arbitrary chat-command API.
function MB:ChatSendBotCommand(botRef, command, bypassThrottle)
    local ok, err = canChat(self)
    if not ok then return false, err end
    local bot = self:ResolveBot(botRef)
    if not bot then return false, "UNKNOWN_BOT" end
    command = self:Trim(command)
    if command == "" then return false, "COMMAND_REQUIRED" end
    local now = self:Now()
    local minInterval = tonumber(self.db.chat.minSendInterval) or 0.25
    if not bypassThrottle and now - (self.chat.lastSendAt or 0) < minInterval then return false, "CHAT_THROTTLED" end
    SendChatMessage(command, "WHISPER", nil, bot.name)
    markSent(self)
    return true
end

function MB:ChatSendGroupCommand(command, bypassThrottle)
    local ok, err = canChat(self)
    if not ok then return false, err end
    command = self:Trim(command)
    if command == "" then return false, "COMMAND_REQUIRED" end
    local channel = self:ChatGroupChannel()
    if not channel then return false, "GROUP_REQUIRED" end
    local now = self:Now()
    local minInterval = tonumber(self.db.chat.minSendInterval) or 0.25
    if not bypassThrottle and now - (self.chat.lastSendAt or 0) < minInterval then return false, "CHAT_THROTTLED" end
    SendChatMessage(command, channel)
    markSent(self)
    return true
end

function MB:ChatSendSequence(sequence, callback, guard, intervalOverride)
    local ok, err = canChat(self)
    if not ok then if callback then self:SafeCall(callback, { sent = 0, failed = #((sequence or {})), errors = { err } }) end; return false, err end
    if type(sequence) ~= "table" or #sequence == 0 then if callback then self:SafeCall(callback, { sent = 0, failed = 0, errors = {} }) end; return false, "EMPTY_SEQUENCE" end

    local configuredInterval = tonumber(self.db.chat.minSendInterval) or 0.25
    local minInterval = math.max(0.05, tonumber(intervalOverride) or configuredInterval)
    local delay = math.max(0, minInterval - (self:Now() - (self.chat.lastSendAt or 0)))
    local result = { sent = 0, failed = 0, errors = {}, total = #sequence }

    for index, item in ipairs(sequence) do
        self:After(delay + (index - 1) * minInterval, function()
            local sent, sendErr
            if type(guard) == "function" and guard() == false then
                sent, sendErr = false, "SEQUENCE_CANCELLED"
            elseif item.route == "GROUP" then
                sent, sendErr = MB:ChatSendGroupCommand(item.command, true)
            else
                sent, sendErr = MB:ChatSendBotCommand(item.bot, item.command, true)
            end
            if sent then result.sent = result.sent + 1
            else
                result.failed = result.failed + 1
                result.errors[#result.errors + 1] = { index = index, route = item.route, bot = item.bot, error = sendErr }
            end
            if index == #sequence and callback then MB:SafeCall(callback, result) end
        end)
    end
    return true
end

-- Presentation suppression is deliberately separate from message processing.
-- ChatFrame filters only hide Core-triggered noise from chat windows; CHAT_MSG_WHISPER
-- still reaches addon event handlers/parsers. This keeps the backend observable while
-- allowing future UI modules to present clean workflows.
local function normalizeWhisperAuthor(author)
    if type(author) ~= "string" then return "" end
    local name = author
    if type(Ambiguate) == "function" then name = Ambiguate(author, "none") or author end
    name = string.match(name, "^[^-]+") or name
    return string.lower(name or "")
end

local function isTradeInventoryDumpStart(message)
    if type(message) ~= "string" then return false end
    return string.find(message, "Inventory", 1, true) ~= nil
        or string.find(message, "背包", 1, true) ~= nil
end

local function isTradeInventoryDumpEnd(message)
    if type(message) ~= "string" then return false end
    return string.find(message, "Off with you", 1, true) ~= nil
        or string.find(message, "再见", 1, true) ~= nil
end

local function isTradeInventoryDumpBody(message)
    if type(message) ~= "string" then return false end
    if string.find(message, "|Hitem:", 1, true) then return true end
    if string.find(message, "^%s*%-%-%-") then return true end
    if string.find(message, "%[.-%]") and (string.find(message, "x%d+") or string.find(message, "soulbound", 1, true)) then return true end
    return false
end

local function isQuestListDumpLine(message)
    if type(message) ~= "string" then return false end
    if string.find(message, "|Hquest:", 1, true) then return true end
    if string.find(message, "^%s*%-%-%-") then return true end
    local lower = string.lower(message)
    if string.find(lower, "quests", 1, true) and (string.find(lower, "incomplete", 1, true) or string.find(lower, "completed", 1, true) or string.find(lower, "all", 1, true)) then return true end
    if string.find(lower, "total:", 1, true) and string.find(lower, "completed:", 1, true) then return true end
    if string.find(lower, "summary", 1, true) then return true end
    return false
end

local function isQuestMutationFeedback(message)
    if type(message) ~= "string" then return false end
    local lower = string.lower((string.gsub(message, "^%s+", "")))
    return string.sub(lower, 1, 13) == "quest removed"
end

local function isQuestAcceptFeedback(message)
    if type(message) ~= "string" then return false end
    local lower = string.lower((string.gsub(message, "^%s+", "")))
    return string.find(lower, "^accepted%s") ~= nil
        or string.find(lower, "^already on%s") ~= nil
        or string.find(lower, "^already completed%s") ~= nil
        or string.find(lower, "^quest already completed%s") ~= nil
        or string.find(lower, "^cannot accept%s") ~= nil
        or string.find(lower, "^can not accept%s") ~= nil
        or string.find(lower, "^can't accept%s") ~= nil
        or string.find(lower, "^could not accept%s") ~= nil
        or string.find(lower, "^not eligible%s") ~= nil
end

function MB:EnsureWhisperPresentationFilter()
    self.chat = self.chat or {}
    if self.chat.presentationFilterInstalled then return true end
    if type(ChatFrame_AddMessageEventFilter) ~= "function" then return false end

    self.chat.presentationFilterInstalled = true
    self.chat.suppressions = self.chat.suppressions or {}
    ChatFrame_AddMessageEventFilter("CHAT_MSG_WHISPER", function(_, _, message, author, ...)
        if not (MB and MB.db and MB.db.chat and MB.db.chat.suppressAutomaticNoise) then return false end
        return MB:ShouldSuppressWhisperPresentation(message, author) == true
    end)
    return true
end

function MB:BeginWhisperPresentationSuppression(kind, botRef, ttl)
    if not (self.db and self.db.chat and self.db.chat.suppressAutomaticNoise) then return false, "SUPPRESSION_DISABLED" end
    local bot = self:ResolveBot(botRef)
    local botName = bot and bot.name or self:NormalizeName(botRef)
    local botKey = self:BotKey(botName)
    if not botKey then return false, "BOT_REQUIRED" end
    if not self:EnsureWhisperPresentationFilter() then return false, "CHAT_FILTER_UNAVAILABLE" end

    kind = self:Upper(kind)
    ttl = tonumber(ttl) or tonumber(self.db.chat.suppressionTTL) or 8
    self.chat.suppressions = self.chat.suppressions or {}
    local key = kind .. ":" .. botKey
    self.chat.suppressions[key] = {
        kind = kind, botKey = botKey, botName = botName,
        startedAt = self:Now(), expiresAt = self:Now() + math.max(1, ttl), active = false,
    }
    self:Emit("MB_CHAT_SUPPRESSION_STARTED", kind, botKey, ttl)
    return true, key
end

function MB:ClearWhisperPresentationSuppression(kind, botRef, reason)
    if not (self.chat and self.chat.suppressions) then return 0 end
    local wantedKind = kind and self:Upper(kind) or nil
    local wantedBotKey = botRef and self:BotKey(type(botRef) == "table" and (botRef.key or botRef.name) or botRef) or nil
    local removed = 0
    for key, state in pairs(self.chat.suppressions) do
        if (not wantedKind or state.kind == wantedKind) and (not wantedBotKey or state.botKey == wantedBotKey) then
            self.chat.suppressions[key] = nil
            removed = removed + 1
            self:Emit("MB_CHAT_SUPPRESSION_ENDED", state.kind, state.botKey, reason or "CLEARED")
        end
    end
    return removed
end

function MB:ShouldSuppressWhisperPresentation(message, author)
    if not (self.chat and self.chat.suppressions) then return false end
    local authorKey = normalizeWhisperAuthor(author)
    local now = self:Now()
    for key, state in pairs(self.chat.suppressions) do
        if state.expiresAt and now > state.expiresAt then
            self.chat.suppressions[key] = nil
            self:Emit("MB_CHAT_SUPPRESSION_ENDED", state.kind, state.botKey, "EXPIRED")
        elseif state.botKey == authorKey then
            if state.kind == "TRADE_INVENTORY_DUMP" then
                if isTradeInventoryDumpStart(message) then
                    state.active = true
                    return true
                end
                if state.active then
                    if isTradeInventoryDumpEnd(message) then
                        self.chat.suppressions[key] = nil
                        self:Emit("MB_CHAT_SUPPRESSION_ENDED", state.kind, state.botKey, "END_MARKER")
                        return true
                    end
                    if isTradeInventoryDumpBody(message) then return true end
                end
                        elseif state.kind == "QUEST_LIST_DUMP" then
                if isQuestListDumpLine(message) then return true end
            elseif state.kind == "QUEST_MUTATION_FEEDBACK" then
                if isQuestMutationFeedback(message) then
                    self.chat.suppressions[key] = nil
                    self:Emit("MB_CHAT_SUPPRESSION_ENDED", state.kind, state.botKey, "FEEDBACK")
                    return true
                end
            elseif state.kind == "QUEST_ACCEPT_FEEDBACK" then
                if isQuestAcceptFeedback(message) then
                    self.chat.suppressions[key] = nil
                    self:Emit("MB_CHAT_SUPPRESSION_ENDED", state.kind, state.botKey, "FEEDBACK")
                    return true
                end
            end
        end
    end
    return false
end

function MB:SuppressNextTradeInventoryDump(botRef)
    return self:BeginWhisperPresentationSuppression("TRADE_INVENTORY_DUMP", botRef, tonumber(self.db and self.db.chat and self.db.chat.suppressionTTL) or 8)
end

