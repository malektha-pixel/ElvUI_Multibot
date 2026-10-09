local _, MB = ...

-- Narrow Playerbots-chat compatibility backend for capabilities not currently
-- exposed by mod-multibot-bridge: autonomous spell exclusions and explicit casts.
-- No generic chat passthrough is exposed publicly.
MB.spellCompat = MB.spellCompat or { exclusions = {}, sequence = 0 }

local function normalizeSpellId(spellId)
    spellId = tonumber(spellId)
    if not spellId or spellId <= 0 or spellId > 2147483647 or math.floor(spellId) ~= spellId then return nil end
    return spellId
end

local function botOnline(self, botRef)
    local bot = self:ResolveBot(botRef)
    if not bot then return nil, "UNKNOWN_BOT" end
    if bot.online ~= true then return nil, "BOT_OFFLINE" end
    return bot
end

local function spellbookHas(self, botRef, spellId)
    local book, meta = self:GetData("BOT.SPELLBOOK", botRef)
    if not book then return nil, meta and (meta.error or meta.status) or "SPELLBOOK_REQUIRED" end
    local byId = type(book.byId) == "table" and book.byId or nil
    if byId then
        local v = byId[spellId] or byId[tostring(spellId)]
        if v ~= nil then return true end
    end
    for _, id in ipairs(book.spellIds or {}) do if tonumber(id) == spellId then return true end end
    return false, "SPELL_NOT_KNOWN"
end

local function exclusionKey(self, botRef)
    local bot = self:ResolveBot(botRef)
    local name = bot and bot.name or self:NormalizeName(botRef)
    return self:BotKey(name), name
end

function MB:ResetSpellCompatibilitySession(reason)
    self.spellCompat = self.spellCompat or {}
    self.spellCompat.exclusions = {}
    local keys = {}
    for key, entry in pairs(self.cache or {}) do
        if entry and entry.meta and entry.meta.domain == "BOT.SPELL_EXCLUSIONS" then keys[#keys + 1] = key end
    end
    for _, key in ipairs(keys) do self.cache[key] = nil end
end

function MB:EnsureSpellExclusionSnapshot(botRef)
    local botKey, name = exclusionKey(self, botRef)
    if not botKey then return nil, "BOT_REQUIRED" end
    self.spellCompat.exclusions = self.spellCompat.exclusions or {}
    local state = self.spellCompat.exclusions[botKey]
    if not state then
        state = {
            schemaVersion = 1, name = name, botKey = botKey,
            excluded = {}, known = {}, requested = {},
            source = "PLAYERBOTS_CHAT_COMPAT",
            authoritative = false,
            complete = false,
            readback = "UNAVAILABLE",
            confidence = "PARTIAL_CORE_OBSERVED",
            sessionScoped = true,
            persistent = false,
            observedAt = self:Now(),
        }
        self.spellCompat.exclusions[botKey] = state
        self:CommitData("BOT.SPELL_EXCLUSIONS", botKey, state, {
            source = state.source, authority = state.confidence, authoritative = false,
            complete = false, persistent = false, sessionScoped = true, sessionEpoch = self.sessionEpoch,
        })
    end
    return state
end

function MB:GetBotSpellEnabled(botRef, spellId)
    spellId = normalizeSpellId(spellId)
    if not spellId then return nil, { status = "ERROR", error = "INVALID_SPELL_ID" } end
    local botKey = exclusionKey(self, botRef)
    if not botKey then return nil, { status = "ERROR", error = "BOT_REQUIRED" } end
    local state = self.spellCompat and self.spellCompat.exclusions and self.spellCompat.exclusions[botKey] or nil
    local requested = state and state.requested and state.requested[spellId] or nil
    if not state or state.known[spellId] == nil then
        return nil, {
            status = "UNKNOWN", error = "EXCLUSION_STATE_UNKNOWN", spellId = spellId,
            authoritative = false, complete = false, source = "PLAYERBOTS_CHAT_COMPAT",
            readback = "UNAVAILABLE", confidence = "NO_AUTHORITATIVE_READBACK",
            requestedEnabled = requested and requested.enabled,
            requestedAt = requested and requested.at or nil,
            requestedTransactionId = requested and requested.transactionId or nil,
        }
    end
    return state.known[spellId] == true, {
        status = "OBSERVED", spellId = spellId, authoritative = false, complete = false,
        source = "PLAYERBOTS_CHAT_COMPAT", readback = "UNAVAILABLE", confidence = "SERVER_REPLY_OBSERVED",
        requestedEnabled = requested and requested.enabled,
    }
end

function MB:GetBotSpellEnabledAvailability(botRef, spellId)
    local details = { enabled = false, reason = nil, spellId = normalizeSpellId(spellId), actionId = "SPELL.EXCLUSION_SET" }
    if not details.spellId then details.reason = "INVALID_SPELL_ID"; return details end
    local bot, err = botOnline(self, botRef)
    if not bot then details.reason = err; return details end
    if not self.db or not self.db.chat or not self.db.chat.enabled then details.reason = "CHAT_DISABLED"; return details end
    if type(SendChatMessage) ~= "function" then details.reason = "SEND_CHAT_UNAVAILABLE"; return details end
    local known, spellErr = spellbookHas(self, bot.name, details.spellId)
    if known == false then details.reason = spellErr or "SPELL_NOT_KNOWN"; return details end
    details.enabled = true
    details.bot = bot.name
    details.spellbookValidated = known == true
    if known == nil then details.validationWarning = spellErr or "SPELLBOOK_REQUIRED" end
    details.verification = "BEST_EFFORT_SENT_NO_READBACK"
    return details
end

function MB:SetBotSpellEnabled(originModule, botRef, spellId, enabled, callback)
    spellId = normalizeSpellId(spellId)
    if not spellId then return nil, "INVALID_SPELL_ID" end
    enabled = enabled == true
    return self:ExecuteAction(originModule, "SPELL.EXCLUSION_SET", botRef, { spellId = spellId, enabled = enabled }, callback)
end

function MB:GetBotSpellCastAvailability(botRef, spellId, options)
    options = type(options) == "table" and options or {}
    local details = { enabled = false, reason = nil, spellId = normalizeSpellId(spellId), actionId = "SPELL.CAST" }
    if not details.spellId then details.reason = "INVALID_SPELL_ID"; return details end
    local bot, err = botOnline(self, botRef)
    if not bot then details.reason = err; return details end
    if not self.db or not self.db.chat or not self.db.chat.enabled then details.reason = "CHAT_DISABLED"; return details end
    if type(SendChatMessage) ~= "function" then details.reason = "SEND_CHAT_UNAVAILABLE"; return details end
    local known, spellErr = spellbookHas(self, bot.name, details.spellId)
    if known == false then details.reason = spellErr or "SPELL_NOT_KNOWN"; return details end
    if known == nil and options.requireSpellbook == true then details.reason = spellErr or "SPELLBOOK_REQUIRED"; return details end
    details.enabled = true
    details.bot = bot.name
    details.spellbookValidated = known == true
    if known == nil then details.validationWarning = spellErr or "SPELLBOOK_REQUIRED" end
    details.serverAuthority = true
    return details
end

function MB:CastBotSpell(originModule, botRef, spellId, options, callback)
    spellId = normalizeSpellId(spellId)
    if not spellId then return nil, "INVALID_SPELL_ID" end
    options = type(options) == "table" and options or {}
    return self:ExecuteAction(originModule, "SPELL.CAST", botRef, { spellId = spellId, requireSpellbook = options.requireSpellbook == true }, callback)
end

function MB:GetBotSpellActionContract(botRef, spellId)
    spellId = normalizeSpellId(spellId)
    if not spellId then return nil, "INVALID_SPELL_ID" end
    local managed = self.GetManagedBot and self:GetManagedBot(botRef) or nil
    local bot = self:ResolveBot(botRef)
    local guid = managed and tonumber(managed.guid) or (bot and tonumber(bot.guid)) or nil
    if not guid or guid <= 0 then return nil, "STABLE_BOT_IDENTITY_REQUIRED" end
    local name = (managed and managed.name) or (bot and bot.name) or self:NormalizeName(botRef)
    local spellName, _, icon
    if type(GetSpellInfo) == "function" then spellName, _, icon = GetSpellInfo(spellId) end
    return {
        kind = "MACRO",
        botGuid = guid,
        botName = name,
        spellId = spellId,
        name = (name or "Bot") .. ": " .. (spellName or ("Spell " .. tostring(spellId))),
        icon = icon,
        slashCommand = "/mbcastguid",
        macroText = "/mbcastguid " .. tostring(guid) .. " " .. tostring(spellId),
        persistent = true,
        requiresCore = true,
    }
end

function MB:HandleBotSpellMacroSlash(input)
    input = self:Trim(input)
    local guidText, spellText = string.match(input, "^(%d+)%s+(%d+)%s*$")
    local guid, spellId = tonumber(guidText), normalizeSpellId(spellText)
    if not guid or guid <= 0 or not spellId then
        self:Print("Usage: /mbcastguid <managed-guid> <spellId>")
        return
    end
    local managed = self.GetManagedBot and self:GetManagedBot(guid) or nil
    if not managed then self:Print("Bot spell cast unavailable: MANAGED_BOT_NOT_FOUND"); return end
    local txId, err = self:CastBotSpell("ElvUI_Multibot_Core_Macro", managed.name, spellId, { requireSpellbook = false })
    if not txId and err then self:Print("Bot spell cast unavailable: " .. tostring(err)) end
end

-- Called after a chat-backed SPELL.EXCLUSION_SET command is successfully sent.
-- Current Playerbots documents mutation syntax but no authoritative exclusion-list
-- query.  A successfully sent command is therefore recorded only as REQUESTED state;
-- Core deliberately does not toggle `excluded`/`known` as though the bot confirmed it.
function MB:RecordSpellExclusionCommand(botRef, spellId, enabled, txId)
    local state, err = self:EnsureSpellExclusionSnapshot(botRef)
    if not state then return false, err end
    spellId = normalizeSpellId(spellId)
    if not spellId then return false, "INVALID_SPELL_ID" end
    state.requested = state.requested or {}
    state.observedAt = self:Now()
    state.lastTransactionId = txId
    state.requested[spellId] = { enabled = enabled == true, at = state.observedAt, transactionId = txId }
    state.lastMutation = { spellId = spellId, enabled = enabled == true, at = state.observedAt, transactionId = txId, status = "SENT_UNVERIFIED" }
    self.spellCompat.exclusions[state.botKey] = state
    self:CommitData("BOT.SPELL_EXCLUSIONS", state.botKey, state, {
        source = "PLAYERBOTS_CHAT_COMPAT", authority = "SENT_UNVERIFIED",
        authoritative = false, complete = false, persistent = false, sessionScoped = true,
        sessionEpoch = self.sessionEpoch, observedAt = state.observedAt,
    })
    return true
end
