-- Quest view for BotInspect: explicit selected-bot reads, no raid-wide polling.
-- Core retains ownership of structured quests, exact links and mutations.
local BotInspect = _G.ElvUI_Multibot_BotInspect
if not BotInspect then return end

local API = BotInspect.api
local MODULE = "ElvUI_Multibot_BotInspect"
local ROWS = 11
local ROW_HEIGHT = 28

local function sameBot(a, b)
    if not a or not b then return false end
    return string.lower(tostring(a)) == string.lower(tostring(b))
end

local function trim(v)
    return (string.gsub(tostring(v or ""), "^%s*(.-)%s*$", "%1"))
end

local function backdrop(frame, alpha)
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        tile = true, tileSize = 8, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    frame:SetBackdropColor(0.025, 0.028, 0.037, alpha or 0.80)
    frame:SetBackdropBorderColor(0.17, 0.19, 0.23, 1)
end

local function label(parent, size, justification)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFont("Fonts\\FRIZQT__.TTF", size or 10, "OUTLINE")
    fs:SetJustifyH(justification or "LEFT")
    fs:SetJustifyV("MIDDLE")
    fs:SetTextColor(0.86, 0.87, 0.90)
    return fs
end

local function button(parent, text, width, height)
    local b = CreateFrame("Button", nil, parent)
    b:SetWidth(width); b:SetHeight(height)
    backdrop(b, 0.78)
    local fs = label(b, 9, "CENTER")
    fs:SetPoint("TOPLEFT", b, "TOPLEFT", 4, -1)
    fs:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -4, 1)
    fs:SetText(text)
    b.text = fs
    b:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(0.25, 0.65, 0.95, 1)
        if self.help then
            GameTooltip:SetOwner(self, "ANCHOR_TOPRIGHT")
            GameTooltip:AddLine(self.helpTitle or tostring(self.text:GetText()), 1, 1, 1)
            GameTooltip:AddLine(self.help, 0.75, 0.78, 0.83, true)
            GameTooltip:Show()
        end
    end)
    b:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(0.17, 0.19, 0.23, 1)
        GameTooltip:Hide()
    end)
    return b
end

-- 3.3.5 has no general questID -> zone/category Lua query.  For quests shared
-- with the player, however, the native quest log already contains the exact
-- Blizzard header and clean localized title.  Keep what we observe for the
-- session so a bot can remain categorized after the player turns the quest in.
BotInspect.questCategoryCache = BotInspect.questCategoryCache or {}
BotInspect.questCategoryOrderCache = BotInspect.questCategoryOrderCache or {}
BotInspect.questCollapsedCategories = BotInspect.questCollapsedCategories or {}

local UNKNOWN_CATEGORY = "Other / Unknown"

local function linkQuestName(link)
    if type(link) ~= "string" then return nil end
    local name = string.match(link, "|h%[([^%]]+)%]|h")
    name = trim(name)
    return name ~= "" and name or nil
end

local function questionDamage(name)
    name = trim(name)
    if name == "" then return 99 end
    local score = 0
    local _, count = string.gsub(name, "%?", "")
    score = score + count
    if count > 1 then score = score + 2 end
    -- These are common replacement-character positions for apostrophes/dashes.
    if string.find(name, "%w%?%w") then score = score + 3 end
    if string.find(name, "%w%?%s") then score = score + 2 end
    if string.find(name, "%s%?%w") then score = score + 2 end
    if string.find(name, "%s%?%s") then score = score + 3 end
    -- A single trailing question mark can be legitimate punctuation, so do not
    -- penalize it beyond the base count when comparing otherwise equal names.
    return score
end

local function comparableQuestName(name)
    name = string.lower(trim(name))
    name = string.gsub(name, "[^%w]+", " ")
    name = string.gsub(name, "^%s+", "")
    name = string.gsub(name, "%s+$", "")
    name = string.gsub(name, "%s+", " ")
    return name
end

local function cleanerName(primary, candidate)
    primary, candidate = trim(primary), trim(candidate)
    if candidate == "" then return primary end
    if primary == "" then return candidate end
    local pDamage, cDamage = questionDamage(primary), questionDamage(candidate)
    if cDamage < pDamage and pDamage >= 3 then
        local pComparable = comparableQuestName(primary)
        local cComparable = comparableQuestName(candidate)
        if pComparable == cComparable or cDamage == 0 then return candidate end
    end
    return primary
end

function BotInspect:RefreshNativeQuestCategoryCache()
    if type(GetNumQuestLogEntries) ~= "function" or type(GetQuestLogTitle) ~= "function" then return end
    local total = GetNumQuestLogEntries()
    total = tonumber(total) or 0
    if total <= 0 then return end

    self.questCategoryCache = self.questCategoryCache or {}
    self.questCategoryOrderCache = self.questCategoryOrderCache or {}
    local currentHeader = UNKNOWN_CATEGORY
    local nextOrder = 0
    for _ in pairs(self.questCategoryOrderCache) do nextOrder = nextOrder + 1 end

    for index = 1, total do
        local title, level, third, fourth, fifth, sixth, seventh, eighth, ninth = GetQuestLogTitle(index)
        if title then
            -- WotLK 3.3.5: title, level, questTag, suggestedGroup, isHeader,
            -- isCollapsed, isComplete, isDaily, questID.
            -- Later Classic clients moved isHeader/questID one slot earlier;
            -- accepting both costs nothing and keeps the helper self-contained.
            local isHeader, questId
            if type(fourth) == "boolean" then
                isHeader = fourth == true
                questId = tonumber(eighth)
            else
                isHeader = fifth == true or fifth == 1
                questId = tonumber(ninth)
            end
            if isHeader then
                currentHeader = trim(title)
                if currentHeader == "" then currentHeader = UNKNOWN_CATEGORY end
                if not self.questCategoryOrderCache[currentHeader] then
                    nextOrder = nextOrder + 1
                    self.questCategoryOrderCache[currentHeader] = nextOrder
                end
            elseif questId and questId > 0 then
                if not self.questCategoryOrderCache[currentHeader] then
                    nextOrder = nextOrder + 1
                    self.questCategoryOrderCache[currentHeader] = nextOrder
                end
                self.questCategoryCache[questId] = {
                    category = currentHeader,
                    categoryOrder = self.questCategoryOrderCache[currentHeader],
                    nativeOrder = index,
                    title = trim(title),
                    level = tonumber(level),
                    source = "PLAYER_QUEST_LOG",
                }
            end
        end
    end
end

local function questieCategory(questId)
    local qdb = _G.QuestieDB
    if not qdb or type(qdb.QueryQuestSingle) ~= "function" then return nil, nil end
    local okZone, zoneOrSort = pcall(qdb.QueryQuestSingle, questId, "zoneOrSort")
    if not okZone or type(zoneOrSort) ~= "number" or zoneOrSort == 0 then return nil, nil end
    local title
    local okTitle, qTitle = pcall(qdb.QueryQuestSingle, questId, "name")
    if okTitle and type(qTitle) == "string" and trim(qTitle) ~= "" then title = trim(qTitle) end

    local loader = _G.QuestieLoader
    if not loader or type(loader.ImportModule) ~= "function" then return nil, title end
    local okUtils, utils = pcall(loader.ImportModule, loader, "TrackerUtils")
    if not okUtils or type(utils) ~= "table" then return nil, title end
    local method = zoneOrSort > 0 and utils.GetZoneNameByID or utils.GetCategoryNameByID
    if type(method) ~= "function" then return nil, title end
    local okName, category = pcall(method, utils, zoneOrSort)
    category = okName and trim(category) or ""
    if category == "" or string.lower(category) == "unknown" or string.lower(category) == "unknown zone" then category = nil end
    return category, title
end

function BotInspect:GetQuestPresentation(entry)
    local questId = tonumber(entry and (entry.questId or entry.id)) or 0
    local native = questId > 0 and self.questCategoryCache and self.questCategoryCache[questId] or nil
    local qCategory, qTitle
    if questId > 0 then qCategory, qTitle = questieCategory(questId) end

    local name = trim(entry and entry.name or "")
    local exactName = linkQuestName(entry and (entry.exactLink or entry.link))
    if native and trim(native.title) ~= "" then name = native.title end
    if qTitle then name = cleanerName(name, qTitle) end
    if exactName then name = cleanerName(name, exactName) end
    if name == "" then name = tostring(questId) end

    local category = native and trim(native.category) or ""
    local source = native and native.source or nil
    local categoryOrder = native and tonumber(native.categoryOrder) or nil
    local nativeOrder = native and tonumber(native.nativeOrder) or nil
    if category == "" and qCategory then
        category, source = qCategory, "QUESTIE"
    end
    if category == "" then category, source = UNKNOWN_CATEGORY, "UNRESOLVED" end
    if not categoryOrder then
        categoryOrder = self.questCategoryOrderCache and self.questCategoryOrderCache[category] or nil
    end
    return {
        name = name,
        category = category,
        categorySource = source,
        categoryOrder = categoryOrder,
        nativeOrder = nativeOrder,
    }
end

function BotInspect:RefreshSelectedQuests(withMetadata)
    local bot = self.selectedBot
    if not bot or self.activeView ~= "QUESTS" or not self.frame or not self.frame:IsShown() then return nil, "QUEST_TAB_INACTIVE" end
    if not self:IsBotOnline(bot) then
        self.questRefreshState = { bot = bot, state = "OFFLINE" }
        self:RenderQuests()
        return nil, "BOT_OFFLINE"
    end
    if self.questRefreshState and sameBot(self.questRefreshState.bot, bot) and self.questRefreshState.state == "PENDING" then
        return self.questRefreshState.readId, "ALREADY_PENDING"
    end
    local generation = (tonumber(self.questRefreshGeneration) or 0) + 1
    self.questRefreshGeneration = generation
    self.questRefreshState = { bot = bot, state = "PENDING" }
    self:SetStatus("Reading " .. bot .. "'s structured quests through Core...")
    self:RenderQuests()
    local function active()
        return generation == BotInspect.questRefreshGeneration and sameBot(BotInspect.selectedBot, bot)
            and BotInspect.activeView == "QUESTS" and BotInspect.frame and BotInspect.frame:IsShown()
    end
    local readId, err = API:Refresh("BOT.QUESTS", bot, function(quests, meta)
        if not active() then return end
        if not quests or (meta and meta.status == "ERROR") then
            BotInspect.questRefreshState = { bot = bot, state = "ERROR", reason = meta and meta.error or "QUEST_READ_FAILED" }
            BotInspect:SetStatus("Quest read failed: " .. tostring(meta and meta.error or "QUEST_READ_FAILED"), 1, 0.48, 0.38)
            BotInspect:RenderQuests()
            return
        end
        BotInspect.questRefreshState = { bot = bot, state = "READY" }
        BotInspect:RenderQuests()
        if withMetadata ~= true then return end
        BotInspect.questRefreshState = { bot = bot, state = "METADATA" }
        local metaId, metaErr = API:RefreshQuestMetadata(bot, function(metadata, metadataMeta)
            if not active() then return end
            if not metadata or (metadataMeta and metadataMeta.status == "ERROR") then
                BotInspect.questRefreshState = { bot = bot, state = "PARTIAL", reason = metadataMeta and metadataMeta.error or "QUEST_METADATA_UNAVAILABLE" }
                BotInspect:SetStatus("Quest list available; names/links may be incomplete: " .. tostring(BotInspect.questRefreshState.reason), 0.90, 0.70, 0.32)
            else
                BotInspect.questRefreshState = { bot = bot, state = "READY" }
                BotInspect:SetStatus("Quest log and Playerbots quest metadata refreshed for " .. bot .. ".")
            end
            BotInspect:RenderQuests()
        end)
        if not metaId and active() then
            BotInspect.questRefreshState = { bot = bot, state = "PARTIAL", reason = metaErr or "METADATA_UNAVAILABLE" }
            BotInspect:SetStatus("Quest list available; metadata request: " .. tostring(metaErr or "unavailable"), 0.90, 0.70, 0.32)
            BotInspect:RenderQuests()
        end
    end)
    if not readId then
        self.questRefreshState = { bot = bot, state = "ERROR", reason = err or "QUEST_READ_UNAVAILABLE" }
        self:SetStatus("Quest read unavailable: " .. tostring(err), 1, 0.48, 0.38)
        self:RenderQuests()
    else
        if self.questRefreshState and self.questRefreshState.state == "PENDING" then self.questRefreshState.readId = readId end
    end
    return readId, err
end

function BotInspect:PromptAbandonQuest(botName, quest)
    if not botName or not quest then return end
    local questId = tonumber(quest.questId or quest.id)
    if not questId then return end
    local avail = API:GetQuestActionAvailability(botName, "ABANDON", questId, { confirmed = true })
    if not avail or not avail.enabled then
        self:SetStatus("Cannot abandon: " .. tostring(avail and avail.reason or "QUEST_UNAVAILABLE"), 1, 0.50, 0.36)
        return
    end
    local popup = StaticPopup_Show("ELVUI_MULTIBOT_BOTINSPECT_ABANDON_QUEST", quest.name or tostring(questId), botName)
    if popup then popup.data = { bot = botName, questId = questId } end
end

function BotInspect:ExecuteConfirmedQuestAbandon(botName, questId)
    local avail = API:GetQuestActionAvailability(botName, "ABANDON", questId, { confirmed = true })
    if not avail or not avail.enabled then
        self:SetStatus("Abandon unavailable: " .. tostring(avail and avail.reason or "QUEST_UNAVAILABLE"), 1, 0.45, 0.35)
        return
    end
    local id, err = API:ExecuteQuestAction(MODULE, botName, "ABANDON", questId, { confirmed = true }, function(tx)
        if not sameBot(BotInspect.selectedBot, botName) then return end
        BotInspect:SetStatus("Abandon quest: " .. tostring(tx and tx.state or "UNKNOWN") .. (tx and tx.error and (" (" .. tostring(tx.error) .. ")") or ""))
        BotInspect:RenderQuests()
    end)
    if id then self:SetStatus("Abandon request started for quest " .. tostring(questId) .. ".")
    else self:SetStatus("Abandon failed: " .. tostring(err), 1, 0.45, 0.35) end
end

function BotInspect:ExecuteQuestNpc(kind, botName, confirmed)
    local avail = API:GetQuestNpcActionAvailability(botName, kind, { confirmed = confirmed == true })
    if not avail or not avail.enabled then
        self:SetStatus("NPC quest action unavailable: " .. tostring(avail and avail.reason or "UNKNOWN"), 1, 0.52, 0.32)
        return nil, avail and avail.reason
    end
    local id, err = API:ExecuteQuestNpcAction(MODULE, botName, kind, { confirmed = confirmed == true }, function(tx)
        if sameBot(BotInspect.selectedBot, botName) then
            if tx and tx.state == "SENT_UNVERIFIED" then
                BotInspect:SetStatus("Command sent to " .. botName .. ". Outcome not yet verified; refresh quests to check.", 0.50, 0.80, 1.0)
            else
                BotInspect:SetStatus("NPC command: " .. tostring(tx and tx.state or "UNKNOWN") .. " " .. tostring(tx and tx.error or ""), 0.95, 0.67, 0.32)
            end
            if BotInspect.activeView == "QUESTS" and type(BotInspect.ScheduleLocal) == "function" then
                BotInspect:ScheduleLocal("quest-npc-refresh", 1.8, function()
                    if sameBot(BotInspect.selectedBot, botName) and BotInspect.activeView == "QUESTS" then
                        BotInspect:RefreshSelectedQuests(true)
                    end
                end)
            end
        end
    end)
    if id then self:SetStatus((kind == "TALK_TARGET" and "Talk" or "Accept nearby") .. " requested for " .. botName .. ".")
    else self:SetStatus("NPC action rejected: " .. tostring(err), 1, 0.48, 0.35) end
    return id, err
end

function BotInspect:PromptQuestNpcAction(kind, botName)
    if kind == "TALK_TARGET" then
        local avail = API:GetQuestNpcActionAvailability(botName, kind, { confirmed = true })
        if not avail or not avail.enabled then
            self:SetStatus("Talk unavailable: " .. tostring(avail and avail.reason or "UNKNOWN"), 1, 0.52, 0.32)
            return
        end
        local targetName = type(UnitName) == "function" and UnitName("target") or "current target"
        local dialog = StaticPopup_Show("ELVUI_MULTIBOT_BOTINSPECT_TALK_QUEST", botName, targetName)
        if dialog then dialog.data = { bot = botName, kind = kind, targetGuid = type(UnitGUID) == "function" and UnitGUID("target") or nil } end
        return
    end
    self:ExecuteQuestNpc(kind, botName, false)
end

function BotInspect:RegisterQuestContextActions()
    API:RegisterContextAction(MODULE, {
        id = "quest_open_log", contexts = { "BOT", "UNITFRAME" }, path = { "Quests" }, order = 30,
        label = "Open Quest Log", requirements = { bot = true },
        handler = function(context)
            local bot = context and (context.bot or context.botName or context.target)
            if type(bot) == "table" then bot = bot.name end
            if bot then BotInspect:Open(bot); BotInspect:SetActiveView("QUESTS") end
        end,
    })
    API:RegisterContextAction(MODULE, {
        id = "quest_accept_nearby", contexts = { "BOT", "UNITFRAME" }, path = { "Quests" }, order = 31,
        label = "Accept Nearby Quests", requirements = { bot = true },
        enabled = function(context)
            local bot = context and (context.bot or context.botName or context.target)
            if type(bot) == "table" then bot = bot.name end
            local avail = API:GetQuestNpcActionAvailability(bot, "ACCEPT_NEARBY")
            return avail and avail.enabled == true, avail and avail.reason or "NPC_UNAVAILABLE"
        end,
        handler = function(context)
            local bot = context and (context.bot or context.botName or context.target)
            if type(bot) == "table" then bot = bot.name end
            if bot then BotInspect:ExecuteQuestNpc("ACCEPT_NEARBY", bot, false) end
        end,
    })
    API:RegisterContextAction(MODULE, {
        id = "quest_talk_target", contexts = { "BOT", "UNITFRAME" }, path = { "Quests" }, order = 32,
        label = "Talk / Turn In to Target...", requirements = { bot = true },
        enabled = function(context)
            local bot = context and (context.bot or context.botName or context.target)
            if type(bot) == "table" then bot = bot.name end
            local avail = API:GetQuestNpcActionAvailability(bot, "TALK_TARGET", { confirmed = true })
            return avail and avail.enabled == true, avail and avail.reason or "NPC_UNAVAILABLE"
        end,
        handler = function(context)
            local bot = context and (context.bot or context.botName or context.target)
            if type(bot) == "table" then bot = bot.name end
            if bot then BotInspect:PromptQuestNpcAction("TALK_TARGET", bot) end
        end,
    })
end

function BotInspect:BuildQuestsArea(parent)
    local root = CreateFrame("Frame", nil, parent)
    root:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    root:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)
    root:Hide()
    self.frame.questsView = root
    backdrop(root, 0.52)

    local heading = label(root, 14)
    heading:SetPoint("TOPLEFT", root, "TOPLEFT", 12, -12)
    heading:SetText("Quest Log")
    root.heading = heading
    local source = label(root, 9, "RIGHT")
    source:SetWidth(385)
    source:SetPoint("TOPRIGHT", root, "TOPRIGHT", -10, -12)
    source:SetTextColor(0.65, 0.69, 0.74)
    root.source = source

    local refresh = button(root, "Refresh Log", 95, 22)
    refresh:SetPoint("TOPLEFT", root, "TOPLEFT", 10, -40)
    refresh.help = "Read the selected bot's authoritative quest state, then request human-readable quest names and exact links through Core's on-demand Playerbots metadata service."
    refresh:SetScript("OnClick", function() BotInspect:RefreshSelectedQuests(true) end)
    local accept = button(root, "Accept Nearby", 118, 22)
    accept:SetPoint("LEFT", refresh, "RIGHT", 7, 0)
    accept.helpTitle = "Accept Nearby Quests"
    accept.help = "Whispers 'accept *' to this online bot. Playerbots may use quests from nearby questgivers. Select a friendly NPC first; the request is not guaranteed to succeed."
    accept:SetScript("OnClick", function() if BotInspect.selectedBot then BotInspect:PromptQuestNpcAction("ACCEPT_NEARBY", BotInspect.selectedBot) end end)
    local talk = button(root, "Talk / Turn In...", 122, 22)
    talk:SetPoint("LEFT", accept, "RIGHT", 7, 0)
    talk.help = "Have the bot talk to your current friendly NPC target. Playerbots may turn in completed quests and choose rewards automatically. A confirmation is required."
    talk:SetScript("OnClick", function() if BotInspect.selectedBot then BotInspect:PromptQuestNpcAction("TALK_TARGET", BotInspect.selectedBot) end end)
    root.refresh = refresh; root.accept = accept; root.talk = talk

    local summary = label(root, 9)
    summary:SetWidth(310)
    summary:SetPoint("LEFT", talk, "RIGHT", 10, 0)
    summary:SetTextColor(0.65, 0.76, 0.85)
    root.summary = summary

    local search = CreateFrame("EditBox", nil, root)
    search:SetWidth(440); search:SetHeight(22)
    search:SetPoint("TOPLEFT", root, "TOPLEFT", 10, -75)
    search:SetAutoFocus(false); search:SetMaxLetters(64)
    search:SetFont("Fonts\\FRIZQT__.TTF", 10, "")
    search:SetTextColor(0.86, 0.86, 0.90)
    search:SetTextInsets(7, 7, 0, 0)
    backdrop(search, 0.78)
    local placeholder = label(search, 9)
    placeholder:SetPoint("LEFT", search, "LEFT", 7, 0)
    placeholder:SetText("Search quests by name or ID...")
    placeholder:SetTextColor(0.46, 0.49, 0.55)
    search:SetScript("OnTextChanged", function(self)
        if trim(self:GetText()) == "" and not self:HasFocus() then placeholder:Show() else placeholder:Hide() end
        BotInspect.questOffset = 0
        BotInspect:RenderQuests()
    end)
    search:SetScript("OnEditFocusGained", function() placeholder:Hide() end)
    search:SetScript("OnEditFocusLost", function(self) if trim(self:GetText()) == "" then placeholder:Show() end end)
    search:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    root.search = search

    root.filters = {}
    local defs = { { "ALL", "All" }, { "I", "In Progress" }, { "C", "Complete" } }
    for i, def in ipairs(defs) do
        local filter = button(root, def[2], i == 2 and 89 or 74, 22)
        if i == 1 then filter:SetPoint("LEFT", search, "RIGHT", 6, 0) else filter:SetPoint("LEFT", root.filters[i-1], "RIGHT", 5, 0) end
        filter:SetScript("OnClick", function()
            BotInspect.questFilter = def[1]
            BotInspect.questOffset = 0
            BotInspect:RenderQuests()
        end)
        filter.filter = def[1]
        root.filters[i] = filter
    end

    local list = CreateFrame("Frame", nil, root)
    list:SetPoint("TOPLEFT", root, "TOPLEFT", 9, -108)
    list:SetWidth(741); list:SetHeight(ROW_HEIGHT * ROWS + 5)
    root.rows = {}
    root.list = list
    for i = 1, ROWS do
        local row = CreateFrame("Button", nil, list)
        row:SetWidth(729); row:SetHeight(ROW_HEIGHT-2)
        row:SetPoint("TOPLEFT", list, "TOPLEFT", 0, -((i-1)*ROW_HEIGHT))
        backdrop(row, i % 2 == 1 and 0.53 or 0.69)
        local name = label(row, 10)
        name:SetPoint("LEFT", row, "LEFT", 10, 0); name:SetWidth(485)
        local details = label(row, 9, "RIGHT")
        details:SetPoint("RIGHT", row, "RIGHT", -101, 0); details:SetWidth(120)
        local abandon = button(row, "Abandon...", 87, 20)
        abandon:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        abandon.help = "Ask Core to abandon this exact quest. Requires confirmation, a fresh structured quest snapshot and Playerbots' exact quest hyperlink."
        abandon:SetScript("OnClick", function(self)
            if self.questId and self.botName then BotInspect:PromptAbandonQuest(self.botName, { questId = self.questId, name = self.questName }) end
        end)
        row.abandon = abandon
        row.name = name
        row.details = details
        row:SetScript("OnClick", function(self)
            if self.kind == "HEADER" and self.categoryKey then
                BotInspect.questCollapsedCategories = BotInspect.questCollapsedCategories or {}
                BotInspect.questCollapsedCategories[self.categoryKey] = not BotInspect.questCollapsedCategories[self.categoryKey]
                BotInspect.questOffset = 0
                BotInspect:RenderQuests()
            end
        end)
        row:SetScript("OnEnter", function(self)
            if self.kind == "HEADER" then
                self:SetBackdropBorderColor(0.38, 0.52, 0.68, 1)
                return
            end
            if not self.quest then return end
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
            local link = self.quest.exactLink or self.quest.link
            local used = false
            if link and type(GameTooltip.SetHyperlink) == "function" then used = pcall(GameTooltip.SetHyperlink, GameTooltip, link) end
            if not used then
                GameTooltip:ClearLines()
                local presentation = BotInspect:GetQuestPresentation(self.quest)
                GameTooltip:AddLine(presentation.name or self.quest.name or tostring(self.quest.questId), 1, 0.88, 0.30)
            end
            GameTooltip:AddLine("Bot: " .. tostring(self.botName), 0.55, 0.80, 1)
            GameTooltip:AddLine("Status: " .. (self.quest.status == "C" and "Complete" or "In progress"), 0.85, 0.86, 0.89)
            GameTooltip:AddLine("Quest ID: " .. tostring(self.quest.questId), 0.60, 0.63, 0.69)
            GameTooltip:Show()
            self:SetBackdropBorderColor(0.23, 0.56, 0.84, 1)
        end)
        row:SetScript("OnLeave", function(self) GameTooltip:Hide(); self:SetBackdropBorderColor(0.17, 0.19, 0.23, 1) end)
        root.rows[i] = row
    end

    local slider = CreateFrame("Slider", nil, root)
    slider:SetOrientation("VERTICAL")
    slider:SetWidth(14); slider:SetHeight(ROWS * ROW_HEIGHT - 5)
    slider:SetPoint("TOPRIGHT", root, "TOPRIGHT", -9, -109)
    slider:SetMinMaxValues(0, 0); slider:SetValueStep(1)
    slider:SetThumbTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
    slider:SetValue(0)
    slider:SetScript("OnValueChanged", function(self, value)
        if root.updatingQuestSlider then return end
        BotInspect.questOffset = math.floor((tonumber(value) or 0) + 0.5)
        BotInspect:RenderQuests()
    end)
    root.slider = slider
    local function wheel(_, delta)
        BotInspect.questOffset = math.max(0, math.min(tonumber(root.questMaxOffset) or 0,
            (tonumber(BotInspect.questOffset) or 0) - (tonumber(delta) or 0)*3))
        BotInspect:RenderQuests()
    end
    list:EnableMouseWheel(true); list:SetScript("OnMouseWheel", wheel)
    root:EnableMouseWheel(true); root:SetScript("OnMouseWheel", wheel)
    for _, row in ipairs(root.rows) do row:EnableMouseWheel(true); row:SetScript("OnMouseWheel", wheel) end

    local foot = label(root, 9)
    foot:SetPoint("BOTTOMLEFT", root, "BOTTOMLEFT", 10, 11)
    foot:SetWidth(745)
    foot:SetText("Grouped by the player's native quest-log headers when known; Questie is used opportunistically if installed. Unknown bot-only quests remain under Other / Unknown.")
    foot:SetTextColor(0.54, 0.58, 0.63)
    return root
end

function BotInspect:RenderQuests()
    local root = self.frame and self.frame.questsView
    if not root then return end
    local botName = self.selectedBot
    local online = botName and self:IsBotOnline(botName)
    local view, meta = nil, nil
    if online and botName then view, meta = API:GetQuestView(botName) end
    local state = self.questRefreshState
    local stateText = "NO DATA"
    if not botName then stateText = "SELECT A BOT"
    elseif not online then stateText = "OFFLINE · no retained quest log"
    elseif state and sameBot(state.bot, botName) then stateText = state.state or "NO DATA"
    elseif view then stateText = "CACHED" end
    if meta and meta.stale then stateText = stateText .. " · STALE" end
    root.source:SetText(stateText)
    root.summary:SetText(view and string.format("%d in progress / %d complete", tonumber(view.incompleteCount) or 0, tonumber(view.completedCount) or 0) or "--")
    for _, filter in ipairs(root.filters or {}) do
        local active = (self.questFilter or "ALL") == filter.filter
        filter:SetBackdropBorderColor(active and 0.22 or 0.16, active and 0.70 or 0.19, active and 0.95 or 0.23, 1)
    end
    self:RefreshNativeQuestCategoryCache()
    local groupsByName, groups = {}, {}
    local search = root.search and string.lower(trim(root.search:GetText())) or ""
    local selectedFilter = self.questFilter or "ALL"
    if view then
        for _, entry in ipairs(view.items or {}) do
            local status = entry.status == "C" and "C" or "I"
            local presentation = self:GetQuestPresentation(entry)
            local hay = string.lower(tostring(presentation.name or "") .. " " .. tostring(entry.questId or "") .. " " .. tostring(presentation.category or ""))
            if (selectedFilter == "ALL" or selectedFilter == status) and (search == "" or string.find(hay, search, 1, true)) then
                local category = presentation.category or UNKNOWN_CATEGORY
                local group = groupsByName[category]
                if not group then
                    group = {
                        name = category,
                        items = {},
                        order = presentation.categoryOrder,
                        source = presentation.categorySource,
                    }
                    groupsByName[category] = group
                    groups[#groups + 1] = group
                elseif not group.order and presentation.categoryOrder then
                    group.order = presentation.categoryOrder
                end
                group.items[#group.items + 1] = { quest = entry, presentation = presentation }
            end
        end
    end

    table.sort(groups, function(a, b)
        if a.name == UNKNOWN_CATEGORY and b.name ~= UNKNOWN_CATEGORY then return false end
        if b.name == UNKNOWN_CATEGORY and a.name ~= UNKNOWN_CATEGORY then return true end
        local ao, bo = tonumber(a.order), tonumber(b.order)
        if ao and bo and ao ~= bo then return ao < bo end
        if ao and not bo then return true end
        if bo and not ao then return false end
        return string.lower(a.name) < string.lower(b.name)
    end)

    local list = {}
    for _, group in ipairs(groups) do
        table.sort(group.items, function(a, b)
            local aq, bq = a.quest, b.quest
            local ao, bo = tonumber(a.presentation.nativeOrder), tonumber(b.presentation.nativeOrder)
            if ao and bo and ao ~= bo then return ao < bo end
            local ac, bc = aq.status == "C", bq.status == "C"
            if ac ~= bc then return not ac end
            local an, bn = string.lower(tostring(a.presentation.name)), string.lower(tostring(b.presentation.name))
            if an ~= bn then return an < bn end
            return (tonumber(aq.questId) or 0) < (tonumber(bq.questId) or 0)
        end)
        local collapsed = self.questCollapsedCategories and self.questCollapsedCategories[group.name] == true
        list[#list + 1] = { kind = "HEADER", category = group.name, count = #group.items, collapsed = collapsed, source = group.source }
        if not collapsed then
            for _, wrapped in ipairs(group.items) do
                list[#list + 1] = { kind = "QUEST", quest = wrapped.quest, presentation = wrapped.presentation }
            end
        end
    end

    local maximum = math.max(0, #list - ROWS)
    self.questOffset = math.max(0, math.min(maximum, tonumber(self.questOffset) or 0))
    root.questMaxOffset = maximum
    if root.slider then
        root.updatingQuestSlider = true
        root.slider:SetMinMaxValues(0, maximum)
        root.slider:SetValue(self.questOffset)
        root.updatingQuestSlider = false
    end
    for i, row in ipairs(root.rows or {}) do
        local item = list[i + self.questOffset]
        if item and item.kind == "HEADER" then
            row.kind = "HEADER"
            row.quest = nil
            row.botName = nil
            row.categoryKey = item.category
            row.name:SetWidth(485)
            row.name:SetText((item.collapsed and "|cff8aa5bf▶|r  " or "|cff8aa5bf▼|r  ") .. "|cffffd36b" .. tostring(item.category) .. "|r")
            row.details:SetText(tostring(item.count) .. (item.count == 1 and " quest" or " quests"))
            row.details:SetTextColor(0.66, 0.70, 0.76)
            row.abandon.questId = nil
            row.abandon:Hide()
            row:SetBackdropColor(0.045, 0.055, 0.070, 0.92)
            row:Show()
        elseif item and item.kind == "QUEST" then
            local entry, presentation = item.quest, item.presentation
            row.kind = "QUEST"
            row.categoryKey = nil
            row.quest = entry
            row.botName = botName
            row.name:SetWidth(485)
            row.name:SetText((entry.status == "C" and "|cff5fe090●|r      " or "|cffc0c9d7○|r      ") .. tostring(presentation.name or entry.questId))
            local level = entry.questLevel and ("Lv " .. tostring(entry.questLevel) .. "  ") or ""
            row.details:SetText(level .. (entry.status == "C" and "Complete" or "In progress"))
            row.details:SetTextColor(0.86, 0.87, 0.90)
            row.abandon.questId = tonumber(entry.questId)
            row.abandon.questName = tostring(presentation.name or entry.name)
            row.abandon.botName = botName
            row.abandon:Show()
            if online then row.abandon:EnableMouse(true); row.abandon.text:SetTextColor(0.90, 0.84, 0.80)
            else row.abandon:EnableMouse(false); row.abandon.text:SetTextColor(0.50, 0.50, 0.53) end
            row:SetBackdropColor(0.025, 0.028, 0.037, i % 2 == 1 and 0.53 or 0.69)
            row:Show()
        else
            row.kind = nil
            row.quest = nil
            row.botName = nil
            row.categoryKey = nil
            row.abandon.questId = nil
            row.abandon:Hide()
            row:Hide()
        end
    end
    if root.accept and root.talk then
        local accept = botName and API:GetQuestNpcActionAvailability(botName, "ACCEPT_NEARBY")
        local talk = botName and API:GetQuestNpcActionAvailability(botName, "TALK_TARGET", { confirmed = true })
        root.accept.text:SetTextColor(accept and accept.enabled and 0.9 or 0.53, accept and accept.enabled and 0.9 or 0.53, accept and accept.enabled and 0.9 or 0.53)
        root.talk.text:SetTextColor(talk and talk.enabled and 0.9 or 0.53, talk and talk.enabled and 0.9 or 0.53, talk and talk.enabled and 0.9 or 0.53)
        root.accept:EnableMouse(botName ~= nil and online == true)
        root.talk:EnableMouse(botName ~= nil and online == true)
    end
end

StaticPopupDialogs = StaticPopupDialogs or {}
StaticPopupDialogs["ELVUI_MULTIBOT_BOTINSPECT_ABANDON_QUEST"] = {
    text = "Abandon %s on %s? This removes the quest from that bot's log. Core will verify the result.",
    button1 = YES or "Yes", button2 = NO or "No",
    OnAccept = function(frame)
        local value = frame and frame.data
        if value then BotInspect:ExecuteConfirmedQuestAbandon(value.bot, value.questId) end
    end,
    timeout = 0, whileDead = 1, hideOnEscape = 1, preferredIndex = 3,
}
StaticPopupDialogs["ELVUI_MULTIBOT_BOTINSPECT_TALK_QUEST"] = {
    text = "Tell %s to talk to %s?\n\nPlayerbots may automatically turn in completed quests and choose rewards. Continue?",
    button1 = YES or "Yes", button2 = NO or "No",
    OnAccept = function(frame)
        local value = frame and frame.data
        if not value then return end
        if type(UnitGUID) ~= "function" or UnitGUID("target") ~= value.targetGuid then
            BotInspect:SetStatus("Target changed while confirming. Talk cancelled.", 0.98, 0.67, 0.35)
            return
        end
        BotInspect:ExecuteQuestNpc("TALK_TARGET", value.bot, true)
    end,
    timeout = 0, whileDead = 1, hideOnEscape = 1, preferredIndex = 3,
}
