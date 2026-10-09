local _, MB = ...

MB.questWorkflows = MB.questWorkflows or { byBot = {} }
MB.questMetadataReads = MB.questMetadataReads or { byBot = {} }
MB.questAcceptWorkflows = MB.questAcceptWorkflows or { byBot = {}, byTx = {} }

local function normalizeQuestSelector(self, selector)
    if type(selector) == "number" then return { questId = selector } end
    if type(selector) == "string" then
        local questId = tonumber(selector) or tonumber(string.match(selector, "|Hquest:(%d+):"))
        if questId and questId > 0 then return { questId = questId } end
        local text = self:Trim(selector)
        return text ~= "" and { name = text } or {}
    end
    if type(selector) == "table" then
        return {
            questId = tonumber(selector.questId or selector.id),
            name = selector.name,
        }
    end
    return {}
end

local function questMatches(self, quest, query)
    if query.questId and tonumber(quest.questId or quest.id) ~= tonumber(query.questId) then return false end
    if query.name and self:Lower(self:Trim(quest.name)) ~= self:Lower(self:Trim(query.name)) then return false end
    return true
end

local function questNameIsPlaceholder(self, name, questId)
    name = self:Trim(name or "")
    questId = tonumber(questId or 0) or 0
    return name == "" or (questId > 0 and name == tostring(questId))
end


function MB:ParseQuestLink(value)
    local source = type(value) == "table" and (value.link or value.exactLink or value.questLink) or value
    source = self:Trim(source or "")
    if source == "" then return nil, "EXACT_QUEST_LINK_REQUIRED" end

    local link = string.match(source, "(|c%x%x%x%x%x%x%x%x|Hquest:%d+:[^|]+|h%[[^%]]+%]|h|r)")
        or string.match(source, "(|Hquest:%d+:[^|]+|h%[[^%]]+%]|h)")
    if not link then return nil, "EXACT_QUEST_LINK_REQUIRED" end

    local questId, questLevel = string.match(link, "|Hquest:(%d+):([^|]+)|h")
    questId = tonumber(questId or 0) or 0
    if questId <= 0 then return nil, "INVALID_QUEST_LINK" end
    local name = string.match(link, "|h%[([^%]]+)%]|h") or tostring(questId)
    return {
        questId = questId,
        id = questId,
        questLevel = tonumber(questLevel),
        name = name,
        link = link,
        exactLink = link,
        linkSource = "CALLER_SUPPLIED_EXACT_LINK",
    }
end

function MB:GetQuestMetadata(botRef)
    return self:GetData("BOT.QUEST_METADATA", botRef)
end

function MB:RefreshQuestMetadata(botRef, callback, options)
    return self:RefreshDomain("BOT.QUEST_METADATA", botRef, callback, options)
end

function MB:GetQuestView(botRef)
    local snapshot, meta = self:GetData("BOT.QUESTS", botRef)
    if not snapshot then return nil, meta end
    local metadataSnapshot, metadataMeta = self:GetData("BOT.QUEST_METADATA", botRef)
    local metadataById = metadataSnapshot and metadataSnapshot.byId or {}
    local items, incomplete, completed, byId = {}, {}, {}, {}
    local hydratedNames, exactLinks = 0, 0
    for _, raw in ipairs(snapshot.items or {}) do
        local questId = tonumber(raw.questId or raw.id) or 0
        local rawName = self:Trim(raw.name)
        local enrichment = metadataById and metadataById[questId] or nil
        local name, nameSource
        if not questNameIsPlaceholder(self, rawName, questId) then
            name, nameSource = rawName, "BRIDGE"
        elseif enrichment and self:Trim(enrichment.name) ~= "" then
            name, nameSource = self:Trim(enrichment.name), "PLAYERBOTS_QUESTS_ALL"
            hydratedNames = hydratedNames + 1
        else
            name, nameSource = tostring(questId), "ID_FALLBACK"
        end
        local exactLink = enrichment and self:Trim(enrichment.link) or ""
        if exactLink ~= "" then exactLinks = exactLinks + 1 end
        local quest = {
            questId = questId,
            id = questId,
            name = name,
            nameSource = nameSource,
            status = self:Upper(raw.status),
            link = exactLink ~= "" and exactLink or nil,
            exactLink = exactLink ~= "" and exactLink or nil,
            linkSource = enrichment and enrichment.linkSource or nil,
            questLevel = enrichment and tonumber(enrichment.questLevel) or nil,
        }
        if quest.questId > 0 then
            items[#items + 1] = quest
            byId[quest.questId] = quest
            if quest.status == "C" then completed[#completed + 1] = quest else incomplete[#incomplete + 1] = quest end
        end
    end
    return {
        schemaVersion = 2,
        name = snapshot.name,
        mode = self:Upper(snapshot.mode or "ALL"),
        items = items,
        incomplete = incomplete,
        completed = completed,
        byId = byId,
        totalCount = #items,
        incompleteCount = #incomplete,
        completedCount = #completed,
        metadataHydrated = metadataSnapshot ~= nil,
        metadataHydratedNameCount = hydratedNames,
        metadataExactLinkCount = exactLinks,
        metadataRevision = metadataMeta and metadataMeta.revision or nil,
        metadataStale = metadataMeta and metadataMeta.stale == true or false,
        metadataCoverageComplete = metadataSnapshot ~= nil and exactLinks >= #items,
    }, meta
end

function MB:FindQuests(botRef, query)
    local view, meta = self:GetQuestView(botRef)
    if not view then return nil, meta end
    query = normalizeQuestSelector(self, query)
    local out = {}
    for _, quest in ipairs(view.items or {}) do
        if questMatches(self, quest, query) then out[#out + 1] = self:Copy(quest) end
    end
    return out, meta
end

function MB:ResolveQuest(botRef, selector)
    local view, meta = self:GetQuestView(botRef)
    if not view then return nil, meta and (meta.error or meta.status) or "QUESTS_UNAVAILABLE", meta end
    local query = normalizeQuestSelector(self, selector)
    if not query.questId and self:Trim(query.name) == "" then return nil, "QUEST_SELECTOR_REQUIRED", meta end
    local found
    for _, quest in ipairs(view.items or {}) do
        if questMatches(self, quest, query) then
            if found then return nil, query.name and "AMBIGUOUS_QUEST_NAME" or "AMBIGUOUS_QUEST", meta end
            found = quest
        end
    end
    if not found then return nil, "QUEST_NOT_FOUND", meta end
    return self:Copy(found), nil, meta
end

function MB:GetQuestCapabilities(botRef)
    local view, meta = self:GetQuestView(botRef)
    local metadata, metadataMeta = self:GetQuestMetadata(botRef)
    return {
        schemaVersion = 2,
        structuredRead = true,
        structuredReadSource = "BRIDGE",
        exactServerHyperlinkInStructuredRead = false,
        metadataEnrichment = {
            implemented = true,
            domain = "BOT.QUEST_METADATA",
            route = "CHAT",
            command = "quests all",
            onDemand = true,
            shared = true,
            exactLinkSource = "PLAYERBOTS_QUESTS_ALL",
            cached = metadata ~= nil,
            stale = metadataMeta and metadataMeta.stale == true or false,
            revision = metadataMeta and metadataMeta.revision or nil,
            exactLinkCount = view and view.metadataExactLinkCount or 0,
            hydratedNameCount = view and view.metadataHydratedNameCount or 0,
            coverageComplete = view and view.metadataCoverageComplete or false,
        },
        abandon = {
            implemented = self.actions["QUEST.ABANDON"] ~= nil,
            route = "CHAT",
            requiresConfirmation = true,
            exactLinkPreflight = "PLAYERBOTS_QUESTS_ALL",
            verification = "BRIDGE_QUEST_ABSENT",
            retriesMutation = false,
        },
        accept = {
            implemented = self.actions["QUEST.ACCEPT_LINK"] ~= nil,
            route = "CHAT",
            exactLinkSource = "CALLER_SUPPLIED",
            targetScope = "CORE_TARGET_SPEC",
            verification = "BRIDGE_QUEST_STATE_WITH_PLAYERBOTS_FEEDBACK",
            structuredPresenceVerification = true,
            structuredPrecheck = true,
            perBotOutcomes = { "ACCEPTED", "ALREADY_ON", "ALREADY_COMPLETED", "CANNOT_ACCEPT", "NO_RESPONSE" },
        },
        acceptNearby = { implemented = self.actions["QUEST.ACCEPT_NEARBY"] ~= nil, route = "CHAT", command = "accept *", verification = "CHAT_SENT_UNVERIFIED", targetGuard = "FRIENDLY_NPC_GUID", scope = "BOT" },
        talkTarget = { implemented = self.actions["QUEST.TALK_TARGET"] ~= nil, route = "CHAT", command = "talk", requiresConfirmation = true, mayTurnIn = true, rewardSelection = "PLAYERBOTS_AUTOMATIC", verification = "CHAT_SENT_UNVERIFIED", targetGuard = "FRIENDLY_NPC_GUID", scope = "BOT" },
        reward = { implemented = false, reason = "NOT_SEMANTICALLY_VALIDATED" },
        share = {
            implemented = self.actions["QUEST.ACCEPT_LINK"] ~= nil,
            semanticAlias = "ACCEPT",
            note = "Quest sharing/acceptance is target-scoped by whispering the exact quest link to each resolved bot. Use targetSpec='all' for all registered party bots.",
        },
    }, meta
end

function MB:GetQuestInteractionContract(action)
    action = self:Upper(action)
    if action == "ACCEPT_NEARBY" then
        return {
            action = "ACCEPT_NEARBY", actionId = "QUEST.ACCEPT_NEARBY",
            route = "CHAT", command = "accept *", scope = "BOT",
            requiresFriendlyNpcTarget = true, targetGuidGuard = true,
            questgiverScope = "NEARBY_NPCS_AND_OBJECTS_NOT_STRICTLY_TARGETED",
            verification = "CHAT_SENT_UNVERIFIED",
            retryMutation = false,
        }
    elseif action == "TALK_TARGET" then
        return {
            action = "TALK_TARGET", actionId = "QUEST.TALK_TARGET",
            route = "CHAT", command = "talk", scope = "BOT",
            requiresFriendlyNpcTarget = true, targetGuidGuard = true,
            requiresConfirmation = true, mayTurnIn = true,
            rewardSelection = "PLAYERBOTS_AUTOMATIC",
            verification = "CHAT_SENT_UNVERIFIED",
            retryMutation = false,
        }
    end
    if action == "ABANDON" then
        return {
            action = "ABANDON",
            actionId = "QUEST.ABANDON",
            route = "CHAT",
            destructive = true,
            requiresConfirmation = true,
            requiresFreshStructuredQuest = true,
            exactLinkSource = "PLAYERBOTS_QUESTS_ALL",
            syntheticLinksAllowed = false,
            verification = "BRIDGE_QUEST_ABSENT",
            retryMutation = false,
            note = "Core first whispers quests all, captures the exact Playerbots-generated quest hyperlink, sends drop <exact link> once, then confirms only when BOT.QUESTS no longer contains the quest.",
        }
    elseif action == "ACCEPT" or action == "SHARE" then
        return {
            action = "ACCEPT",
            actionId = "QUEST.ACCEPT_LINK",
            route = "CHAT",
            destructive = false,
            requiresConfirmation = false,
            exactLinkSource = "CALLER_SUPPLIED",
            syntheticLinksAllowed = false,
            targetScope = "CORE_TARGET_SPEC",
            dispatch = "PER_BOT_WHISPER",
            feedback = "PLAYERBOTS_ACCEPT_RESPONSE_OPTIONAL",
            perBotOutcomes = { "ACCEPTED", "ALREADY_ON", "ALREADY_COMPLETED", "CANNOT_ACCEPT", "NO_RESPONSE" },
            verification = "BRIDGE_QUEST_STATE_WITH_OPTIONAL_PLAYERBOTS_RESPONSE",
            structuredPrecheck = true,
            retryMutation = false,
            note = "Core freezes the target set and refreshes BOT.QUESTS first. Bots already carrying the quest are resolved without a redundant whisper; remaining bots receive accept <exact link>. A later BOT.QUESTS appearance can prove ACCEPTED when current Playerbots is silent; recognized Playerbots replies remain supplemental evidence.",
        }
    end
    return nil, "UNSUPPORTED_QUEST_ACTION"
end

function MB:GetQuestActionAvailability(targetSpec, action, selector, options)
    action = self:Upper(action)
    options = type(options) == "table" and options or {}

    if action == "ACCEPT" or action == "SHARE" then
        local quest, linkErr = self:ParseQuestLink(selector)
        if not quest then
            return { enabled = false, reason = linkErr or "EXACT_QUEST_LINK_REQUIRED", action = action }
        end
        local availability = self:GetActionAvailability("QUEST.ACCEPT_LINK", targetSpec, {
            scope = "SET",
            questId = quest.questId,
            questName = quest.name,
            questLevel = quest.questLevel,
            questLink = quest.link,
        })
        availability.quest = self:Copy(quest)
        availability.questAction = "ACCEPT"
        availability.interaction = self:GetQuestInteractionContract("ACCEPT")
        return availability
    end

    if action ~= "ABANDON" then return { enabled = false, reason = "UNSUPPORTED_QUEST_ACTION", action = action } end

    local quest, err, meta = self:ResolveQuest(targetSpec, selector)
    if not quest then
        return { enabled = false, reason = err or "QUEST_NOT_FOUND", action = action, requiredDomain = "BOT.QUESTS", sourceMeta = self:Copy(meta) }
    end
    if meta and meta.stale == true then
        return { enabled = false, reason = "SOURCE_STALE", action = action, quest = quest, requiredDomain = "BOT.QUESTS", sourceMeta = self:Copy(meta) }
    end
    if options.confirmed ~= true then
        return { enabled = false, reason = "CONFIRMATION_REQUIRED", action = action, quest = quest, requiredDomain = "BOT.QUESTS" }
    end

    local availability = self:GetActionAvailability("QUEST.ABANDON", targetSpec, {
        questId = quest.questId,
        questName = quest.name,
        questStatus = quest.status,
        confirmed = true,
    })
    availability.quest = self:Copy(quest)
    availability.questAction = action
    availability.requiredDomain = "BOT.QUESTS"
    availability.interaction = self:GetQuestInteractionContract(action)
    return availability
end

function MB:ExecuteQuestAction(originModule, targetSpec, action, selector, options, callback)
    action = self:Upper(action)
    options = type(options) == "table" and options or {}
    local availability = self:GetQuestActionAvailability(targetSpec, action, selector, options)
    if not availability or availability.enabled ~= true then
        return nil, availability and availability.reason or "QUEST_ACTION_UNAVAILABLE", availability
    end
    local quest = availability.quest

    if action == "ACCEPT" or action == "SHARE" then
        return self:ExecuteAction(originModule, "QUEST.ACCEPT_LINK", targetSpec, {
            scope = "SET",
            questId = quest.questId,
            questName = quest.name,
            questLevel = quest.questLevel,
            questLink = quest.link,
        }, callback)
    end

    return self:ExecuteAction(originModule, "QUEST.ABANDON", targetSpec, {
        questId = quest.questId,
        questName = quest.name,
        questStatus = quest.status,
        confirmed = true,
    }, callback)
end

local function normalizeWhisperAuthor(self, author)
    local value = self:Trim(author or "")
    if value == "" then return nil end
    if type(Ambiguate) == "function" then
        local ok, short = pcall(Ambiguate, value, "none")
        if ok and type(short) == "string" and short ~= "" then value = short end
    end
    value = string.gsub(value, "%-.*$", "")
    return self:NormalizeName(value)
end

local function extractQuestLinkRecords(message)
    local out, seenLinks, seenQuestIds = {}, {}, {}
    if type(message) ~= "string" then return out end
    local function add(link, linkSource)
        if seenLinks[link] then return end
        local questId, questLevel = string.match(link, "|Hquest:(%d+):([^|]+)|h")
        questId = tonumber(questId or 0) or 0
        if questId <= 0 or seenQuestIds[questId] then return end
        local name = string.match(link, "|h%[([^%]]+)%]|h") or tostring(questId)
        seenLinks[link] = true
        seenQuestIds[questId] = true
        out[#out + 1] = {
            questId = questId,
            id = questId,
            name = name,
            questLevel = tonumber(questLevel),
            link = link,
            exactLink = link,
            linkSource = linkSource,
        }
    end
    for link in string.gmatch(message, "(|c%x%x%x%x%x%x%x%x|Hquest:%d+:[^|]+|h%[[^%]]+%]|h|r)") do
        add(link, "PLAYERBOTS_QUESTS_ALL")
    end
    for link in string.gmatch(message, "(|Hquest:%d+:[^|]+|h%[[^%]]+%]|h)") do
        add(link, "PLAYERBOTS_QUESTS_ALL_UNCOLORED")
    end
    return out
end

local function questListSection(self, message, current)
    local lower = self:Lower(message or "")
    if string.find(lower, "incompleted quests", 1, true) or string.find(lower, "incomplete quests", 1, true) then return "I" end
    if string.find(lower, "completed quests", 1, true) then return "C" end
    return current
end

local function questListSummary(self, message)
    local text = self:Trim(message or "")
    local lower = self:Lower(text)
    local isTotal = string.find(lower, "total:", 1, true) ~= nil
        and (string.find(lower, "incompleted:", 1, true) ~= nil or string.find(lower, "incomplete:", 1, true) ~= nil)
        and string.match(lower, "[,%s]completed:%s*%d+") ~= nil
    local isSummary = string.find(lower, "summary", 1, true) ~= nil
    if not isTotal and not isSummary then return nil end
    local total = tonumber(string.match(lower, "total:%s*(%d+)"))
    local capacity = tonumber(string.match(lower, "total:%s*%d+%s*/%s*(%d+)"))
    local incomplete = tonumber(string.match(lower, "incompleted:%s*(%d+)")) or tonumber(string.match(lower, "incomplete:%s*(%d+)"))
    local completed = tonumber(string.match(lower, "[,%s]completed:%s*(%d+)"))
    return { raw = text, total = total, capacity = capacity, incomplete = incomplete, completed = completed }
end

local function getStructuredQuestMap(self, botName)
    local snapshot, meta = self:GetData("BOT.QUESTS", botName)
    local byId, count = {}, 0
    if type(snapshot) == "table" then
        for _, quest in ipairs(snapshot.items or {}) do
            local questId = tonumber(quest.questId or quest.id) or 0
            if questId > 0 then
                byId[questId] = { status = self:Upper(quest.status), name = self:Trim(quest.name) }
                count = count + 1
            end
        end
    end
    return byId, count, meta
end

local function questMetadataCoverage(self, workflow)
    local structured, count, meta = getStructuredQuestMap(self, workflow.botName)
    if not meta or meta.status == "MISSING" then return false, count, structured, meta end
    for questId in pairs(structured) do
        if not workflow.byId[questId] then return false, count, structured, meta end
    end
    return true, count, structured, meta
end

local function clearQuestMetadataRead(self, workflow, reason)
    if not workflow then return end
    if self.questMetadataReads and self.questMetadataReads.byBot and self.questMetadataReads.byBot[workflow.botKey] == workflow then
        self.questMetadataReads.byBot[workflow.botKey] = nil
    end
    if self.ClearWhisperPresentationSuppression then
        local clearReason = reason or "QUEST_METADATA_DONE"
        if clearReason == "COMMITTED" and self.After then
            local botKey = workflow.botKey
            self:After(0.50, function() MB:ClearWhisperPresentationSuppression("QUEST_LIST_DUMP", botKey, clearReason) end)
        else
            self:ClearWhisperPresentationSuppression("QUEST_LIST_DUMP", workflow.botKey, clearReason)
        end
    end
end

function MB:FailQuestMetadataRead(workflow, errorCode)
    if not workflow then return end
    local request = workflow.request
    clearQuestMetadataRead(self, workflow, errorCode)
    if request and request.sessionEpoch == self.sessionEpoch then self:FailRead(request, errorCode or "QUEST_METADATA_FAILED") end
end

function MB:CompleteQuestMetadataRead(workflow, completionProof)
    if not workflow or workflow.epoch ~= self.sessionEpoch then return false end
    if not (self.questMetadataReads and self.questMetadataReads.byBot and self.questMetadataReads.byBot[workflow.botKey] == workflow) then return false end
    local coverageComplete, structuredCount, structuredById, structuredMeta = questMetadataCoverage(self, workflow)
    local items, byId = {}, {}
    for _, questId in ipairs(workflow.order or {}) do
        local record = workflow.byId[questId]
        if record then
            local structured = structuredById[questId]
            local item = self:Copy(record)
            if structured and structured.status ~= "" then item.status = structured.status end
            items[#items + 1] = item
            byId[questId] = item
        end
    end
    local summary = workflow.summary or {}
    local snapshot = {
        schemaVersion = 1,
        name = workflow.botName,
        items = items,
        byId = byId,
        exactLinkCount = #items,
        capturedCount = #items,
        structuredCount = structuredCount,
        coverageComplete = coverageComplete,
        responseComplete = workflow.summarySeen == true,
        completionProof = completionProof or (workflow.summarySeen and "PLAYERBOTS_SUMMARY" or (coverageComplete and "STRUCTURED_COVERAGE" or "PARTIAL")),
        total = summary.total,
        capacity = summary.capacity,
        incompleteCount = summary.incomplete,
        completedCount = summary.completed,
        structuredRevision = structuredMeta and structuredMeta.revision or nil,
    }
    clearQuestMetadataRead(self, workflow, "COMMITTED")
    self:CommitData("BOT.QUEST_METADATA", workflow.botKey, snapshot, {
        source = "PLAYERBOTS_CHAT",
        token = workflow.requestId,
        completionProof = snapshot.completionProof,
    })
    return true
end

function MB:BeginQuestMetadataRead(request)
    local info = request and request.targetInfo or {}
    local bot = self:ResolveBot(info.botName or info.botKey)
    if not bot then return false, "UNKNOWN_BOT" end
    self.questMetadataReads = self.questMetadataReads or { byBot = {} }
    if self.questWorkflows and self.questWorkflows.byBot and self.questWorkflows.byBot[bot.key] then return false, "QUEST_CHAT_BUSY" end
    if self.questAcceptWorkflows and self.questAcceptWorkflows.byBot and self.questAcceptWorkflows.byBot[bot.key] then return false, "QUEST_CHAT_BUSY" end
    local existing = self.questMetadataReads.byBot[bot.key]
    if existing and existing.epoch == self.sessionEpoch then return false, "QUEST_METADATA_BUSY" end

    local workflow = {
        request = request,
        requestId = request.id,
        botKey = bot.key,
        botName = bot.name,
        epoch = self.sessionEpoch,
        stage = "CAPTURE",
        section = nil,
        byId = {},
        order = {},
        startedAt = self:Now(),
        lastMessageAt = self:Now(),
        summarySeen = false,
    }
    self.questMetadataReads.byBot[bot.key] = workflow
    if self.BeginWhisperPresentationSuppression then self:BeginWhisperPresentationSuppression("QUEST_LIST_DUMP", bot.name, 7) end

    local ok, err = self:ChatSendSequence({ { route = "BOT", bot = bot.name, command = "quests all" } }, function(result)
        local current = MB.questMetadataReads and MB.questMetadataReads.byBot and MB.questMetadataReads.byBot[bot.key] or nil
        if current ~= workflow or current.epoch ~= MB.sessionEpoch then return end
        if not result or (tonumber(result.sent) or 0) <= 0 then MB:FailQuestMetadataRead(current, "QUEST_METADATA_QUERY_SEND_FAILED") end
    end, function()
        return workflow.epoch == MB.sessionEpoch and MB.questMetadataReads.byBot[bot.key] == workflow
    end)
    if not ok then
        clearQuestMetadataRead(self, workflow, err or "QUEST_METADATA_QUERY_SEND_FAILED")
        return false, err or "QUEST_METADATA_QUERY_SEND_FAILED"
    end

    local epoch, requestId = workflow.epoch, workflow.requestId
    self:After(5.0, function()
        local current = MB.questMetadataReads and MB.questMetadataReads.byBot and MB.questMetadataReads.byBot[bot.key] or nil
        if not current or current ~= workflow or current.epoch ~= epoch or current.requestId ~= requestId then return end
        local coverageComplete = questMetadataCoverage(MB, current)
        if coverageComplete then MB:CompleteQuestMetadataRead(current, "STRUCTURED_COVERAGE_TIMEOUT")
        else MB:FailQuestMetadataRead(current, "QUEST_METADATA_INCOMPLETE") end
    end)
    return true, request.id
end

function MB:HandleQuestMetadataWhisper(message, author)
    local botName = normalizeWhisperAuthor(self, author)
    local botKey = botName and self:BotKey(botName) or nil
    local workflow = botKey and self.questMetadataReads and self.questMetadataReads.byBot and self.questMetadataReads.byBot[botKey] or nil
    if not workflow or workflow.epoch ~= self.sessionEpoch then return false end

    workflow.lastMessageAt = self:Now()
    workflow.section = questListSection(self, message, workflow.section)
    local records = extractQuestLinkRecords(message)
    local added = false
    for _, record in ipairs(records) do
        if workflow.section then record.status = workflow.section end
        if not workflow.byId[record.questId] then workflow.order[#workflow.order + 1] = record.questId end
        workflow.byId[record.questId] = record
        added = true
    end

    local summary = questListSummary(self, message)
    if summary then
        workflow.summary = summary
        workflow.summarySeen = true
        self:CompleteQuestMetadataRead(workflow, "PLAYERBOTS_SUMMARY")
        return true
    end

    return true
end

function MB:AbortQuestMetadataReads(reason)
    if not (self.questMetadataReads and self.questMetadataReads.byBot) then return 0 end
    local active = {}
    for _, workflow in pairs(self.questMetadataReads.byBot) do active[#active + 1] = workflow end
    for _, workflow in ipairs(active) do clearQuestMetadataRead(self, workflow, reason or "SESSION_RESET") end
    return #active
end

local function extractExactQuestLink(message, wantedQuestId)
    if type(message) ~= "string" then return nil end
    wantedQuestId = tonumber(wantedQuestId or 0) or 0
    if wantedQuestId <= 0 then return nil end

    for link in string.gmatch(message, "(|c%x%x%x%x%x%x%x%x|Hquest:%d+:[^|]+|h.-|h|r)") do
        local questId, questLevel = string.match(link, "|Hquest:(%d+):([^|]+)|h")
        if tonumber(questId or 0) == wantedQuestId then
            return link, tonumber(questLevel), "PLAYERBOTS_QUESTS_ALL"
        end
    end
    for link in string.gmatch(message, "(|Hquest:%d+:[^|]+|h.-|h)") do
        local questId, questLevel = string.match(link, "|Hquest:(%d+):([^|]+)|h")
        if tonumber(questId or 0) == wantedQuestId then
            return link, tonumber(questLevel), "PLAYERBOTS_QUESTS_ALL_UNCOLORED"
        end
    end
    return nil
end

local function questAbsent(snapshot, questId)
    if type(snapshot) ~= "table" then return false end
    questId = tonumber(questId or 0) or 0
    for _, quest in ipairs(snapshot.items or {}) do
        if tonumber(quest.questId or quest.id) == questId then return false end
    end
    return true
end

local function emitQuestVerification(self, tx)
    self:Emit("MB_ACTION_VERIFICATION_UPDATED", tx.id, self:Copy(tx.verification), self:TransactionSnapshot(tx))
end

local function clearWorkflow(self, workflow, reason)
    if not workflow then return end
    if self.questWorkflows and self.questWorkflows.byBot and self.questWorkflows.byBot[workflow.botKey] == workflow then
        self.questWorkflows.byBot[workflow.botKey] = nil
    end
    if self.ClearWhisperPresentationSuppression then
        self:ClearWhisperPresentationSuppression("QUEST_LIST_DUMP", workflow.botKey, reason or "QUEST_WORKFLOW_DONE")
        self:ClearWhisperPresentationSuppression("QUEST_MUTATION_FEEDBACK", workflow.botKey, reason or "QUEST_WORKFLOW_DONE")
    end
end

local function failWorkflow(self, workflow, errorCode)
    local tx = workflow and self.transactions and self.transactions[workflow.txId] or nil
    clearWorkflow(self, workflow, errorCode)
    if not tx or tx.sessionEpoch ~= self.sessionEpoch then return end
    if tx.state == "CONFIRMED" or tx.state == "FAILED" or tx.state == "CANCELLED" or tx.state == "AMBIGUOUS" then return end
    tx.completedAt = self:Now()
    self.runtime.counters.actionsCompleted = self.runtime.counters.actionsCompleted + 1
    self:SetTransactionState(tx, "FAILED", { error = errorCode or "QUEST_WORKFLOW_FAILED" })
    if type(tx.callback) == "function" then self:SafeCall(tx.callback, self:TransactionSnapshot(tx)) end
end

function MB:BeginQuestAbandon(tx)
    local bot = tx and tx.targets and tx.targets[1]
    local args = tx and tx.args or {}
    local questId = tonumber(args.questId) or 0
    if not tx or not bot or questId <= 0 then return false, "INVALID_QUEST" end
    self.questWorkflows = self.questWorkflows or { byBot = {} }
    local existing = self.questWorkflows.byBot[bot.key]
    if existing and existing.epoch == self.sessionEpoch then return false, "QUEST_WORKFLOW_BUSY" end
    local metadataRead = self.questMetadataReads and self.questMetadataReads.byBot and self.questMetadataReads.byBot[bot.key] or nil
    if metadataRead and metadataRead.epoch == self.sessionEpoch then return false, "QUEST_CHAT_BUSY" end
    local acceptWorkflow = self.questAcceptWorkflows and self.questAcceptWorkflows.byBot and self.questAcceptWorkflows.byBot[bot.key] or nil
    if acceptWorkflow and acceptWorkflow.epoch == self.sessionEpoch then return false, "QUEST_CHAT_BUSY" end

    local workflow = {
        txId = tx.id,
        botKey = bot.key,
        botName = bot.name,
        questId = questId,
        questName = self:Trim(args.questName),
        questStatus = self:Upper(args.questStatus),
        epoch = self.sessionEpoch,
        stage = "RESOLVE_LINK",
        startedAt = self:Now(),
    }
    self.questWorkflows.byBot[bot.key] = workflow
    tx.questReference = {
        questId = questId,
        name = workflow.questName,
        status = workflow.questStatus,
        linkSource = "PENDING_PLAYERBOTS_QUESTS_ALL",
    }
    tx.stage = "RESOLVE_SERVER_QUEST_LINK"
    if self.BeginWhisperPresentationSuppression then self:BeginWhisperPresentationSuppression("QUEST_LIST_DUMP", bot.name, 6) end

    local ok, err = self:ChatSendSequence({ { route = "BOT", bot = bot.name, command = "quests all" } }, function(result)
        local current = MB.questWorkflows and MB.questWorkflows.byBot and MB.questWorkflows.byBot[bot.key] or nil
        local currentTx = MB.transactions and MB.transactions[tx.id] or nil
        if current ~= workflow or not currentTx or currentTx.sessionEpoch ~= workflow.epoch or currentTx.state ~= "DISPATCHING" then return end
        if not result or (tonumber(result.sent) or 0) <= 0 then failWorkflow(MB, workflow, "QUEST_LINK_QUERY_SEND_FAILED") end
    end, function()
        return tx.sessionEpoch == MB.sessionEpoch and tx.state == "DISPATCHING" and MB.questWorkflows.byBot[bot.key] == workflow
    end)
    if not ok then
        clearWorkflow(self, workflow, err or "QUEST_LINK_QUERY_SEND_FAILED")
        return false, err or "QUEST_LINK_QUERY_SEND_FAILED"
    end

    local txId, epoch = tx.id, self.sessionEpoch
    self:After(5.0, function()
        local current = MB.questWorkflows and MB.questWorkflows.byBot and MB.questWorkflows.byBot[bot.key] or nil
        local currentTx = MB.transactions and MB.transactions[txId] or nil
        if current == workflow and current.stage == "RESOLVE_LINK" and current.epoch == epoch and currentTx and currentTx.state == "DISPATCHING" then
            failWorkflow(MB, current, "QUEST_LINK_UNAVAILABLE")
        end
    end)
    return true
end

function MB:DispatchResolvedQuestAbandon(workflow, link, questLevel, linkSource)
    local tx = workflow and self.transactions and self.transactions[workflow.txId] or nil
    if not tx or tx.sessionEpoch ~= self.sessionEpoch or tx.state ~= "DISPATCHING" then return false, "CANCELLED" end
    workflow.stage = "DROP"
    workflow.link = link
    workflow.linkSource = linkSource
    workflow.questLevel = questLevel
    tx.questReference = self:Merge(tx.questReference or {}, {
        link = link,
        linkSource = linkSource,
        questLevel = questLevel,
    })
    tx.stage = "DROP_QUEST"
    tx.sentAt = self:Now()
    self:SetTransactionState(tx, "SENT")
    if self.BeginWhisperPresentationSuppression then self:BeginWhisperPresentationSuppression("QUEST_MUTATION_FEEDBACK", workflow.botName, 6) end

    local ok, err = self:ChatSendSequence({ { route = "BOT", bot = workflow.botName, command = "drop " .. link } }, function(result)
        local currentTx = MB.transactions and MB.transactions[workflow.txId] or nil
        if not currentTx or currentTx.sessionEpoch ~= workflow.epoch or currentTx.state ~= "SENT" then return end
        if not result or (tonumber(result.sent) or 0) <= 0 then
            failWorkflow(MB, workflow, "QUEST_DROP_SEND_FAILED")
            return
        end
        workflow.stage = "VERIFY"
        currentTx.completedAt = MB:Now()
        currentTx.result = MB:Merge(currentTx.result or {}, {
            sent = true,
            questReference = MB:Copy(currentTx.questReference),
            linkSource = linkSource,
        })
        MB.runtime.counters.actionsCompleted = MB.runtime.counters.actionsCompleted + 1
        MB:ApplyActionInvalidation(currentTx, currentTx.result)
        MB:SetTransactionState(currentTx, "SENT_UNVERIFIED")
        MB:BeginQuestPostVerification(currentTx, workflow)
        if type(currentTx.callback) == "function" then MB:SafeCall(currentTx.callback, MB:TransactionSnapshot(currentTx)) end
    end, function()
        return tx.sessionEpoch == MB.sessionEpoch and tx.state == "SENT" and MB.questWorkflows.byBot[workflow.botKey] == workflow
    end)
    if not ok then
        failWorkflow(self, workflow, err or "QUEST_DROP_SEND_FAILED")
        return false, err
    end
    return true
end

function MB:BeginQuestPostVerification(tx, workflow)
    if not tx or tx.state ~= "SENT_UNVERIFIED" or not workflow then return false end
    tx.verification = {
        status = "PENDING",
        policy = "BRIDGE_QUEST_ABSENT",
        action = "ABANDON",
        questId = workflow.questId,
        attempts = 0,
        startedAt = self:Now(),
    }
    emitQuestVerification(self, tx)
    local txId, epoch = tx.id, tx.sessionEpoch
    self:After(0.45, function() MB:RunQuestPostVerification(txId, epoch, 1) end)
    return true
end

function MB:CompleteQuestVerification(tx, workflow, status, proof, meta)
    if not tx or not tx.verification then return end
    tx.verification.status = status
    tx.verification.proof = proof
    tx.verification.questRevision = meta and meta.revision or tx.verification.questRevision
    tx.verification.completedAt = self:Now()
    emitQuestVerification(self, tx)
    clearWorkflow(self, workflow, status)
    if status == "CONFIRMED" and tx.state == "SENT_UNVERIFIED" then
        self:SetTransactionState(tx, "CONFIRMED", { verifiedAt = self:Now(), verifiedBy = "BOT.QUESTS" })
    end
end

function MB:RunQuestPostVerification(txId, epoch, attempt)
    local tx = self.transactions and self.transactions[txId] or nil
    if not tx or tx.sessionEpoch ~= epoch or tx.state ~= "SENT_UNVERIFIED" or not tx.verification then return end
    local bot = tx.targets and tx.targets[1]
    if not bot then return end
    local workflow = self.questWorkflows and self.questWorkflows.byBot and self.questWorkflows.byBot[bot.key] or nil
    if not workflow or workflow.txId ~= txId then return end
    tx.verification.attempts = math.max(tonumber(tx.verification.attempts) or 0, tonumber(attempt) or 1)
    emitQuestVerification(self, tx)

    self:RefreshDomain("BOT.QUESTS", bot.name, function(quests, meta)
        local current = MB.transactions and MB.transactions[txId] or nil
        if not current or current.sessionEpoch ~= epoch or current.state ~= "SENT_UNVERIFIED" then return end
        local currentWorkflow = MB.questWorkflows and MB.questWorkflows.byBot and MB.questWorkflows.byBot[bot.key] or nil
        if not currentWorkflow or currentWorkflow.txId ~= txId then return end
        current.verification.questRevision = meta and meta.revision or nil
        current.verification.questError = meta and meta.error or nil
        if questAbsent(quests, currentWorkflow.questId) then
            MB:CompleteQuestVerification(current, currentWorkflow, "CONFIRMED", "BRIDGE_QUEST_ABSENT", meta)
            return
        end
        emitQuestVerification(MB, current)
        if attempt < 3 then
            local delays = { [1] = 0.75, [2] = 1.20 }
            MB:After(delays[attempt] or 0.9, function() MB:RunQuestPostVerification(txId, epoch, attempt + 1) end)
        else
            MB:CompleteQuestVerification(current, currentWorkflow, "UNVERIFIED", "POSTCONDITION_NOT_OBSERVED", meta)
        end
    end)
end

local ACCEPT_OUTCOME_PATTERNS = {
    { code = "ALREADY_COMPLETED", patterns = { "^already completed%s", "^quest already completed%s" } },
    { code = "ALREADY_ON", patterns = { "^already on%s", "^already have%s", "^already has%s", "^i have this quest", "^i already have this quest" } },
    { code = "CANNOT_ACCEPT", patterns = { "^cannot accept%s", "^can not accept%s", "^can't accept%s", "^could not accept%s", "^not eligible%s", "^i can't take this quest", "^i cannot take this quest", "^i can not take this quest" } },
    { code = "ACCEPTED", patterns = { "^accepted%s", "^quest accepted" } },
}

local function parseQuestAcceptOutcome(self, message)
    local raw = self:Trim(message or "")
    local lower = self:Lower(raw)
    for _, entry in ipairs(ACCEPT_OUTCOME_PATTERNS) do
        for _, pattern in ipairs(entry.patterns) do
            if string.find(lower, pattern) then return entry.code, raw end
        end
    end
    return nil
end

local function findQuest(snapshot, questId)
    if type(snapshot) ~= "table" then return nil end
    questId = tonumber(questId or 0) or 0
    for _, quest in ipairs(snapshot.items or {}) do
        if tonumber(quest.questId or quest.id) == questId then return quest end
    end
    return nil
end

local function questPresent(snapshot, questId)
    return findQuest(snapshot, questId) ~= nil
end

local function clearQuestAcceptWorkflow(self, workflow, reason)
    if not workflow then return end
    if self.questAcceptWorkflows then
        if self.questAcceptWorkflows.byTx and self.questAcceptWorkflows.byTx[workflow.txId] == workflow then self.questAcceptWorkflows.byTx[workflow.txId] = nil end
        if self.questAcceptWorkflows.byBot then
            for botKey in pairs(workflow.expected or {}) do
                if self.questAcceptWorkflows.byBot[botKey] == workflow then self.questAcceptWorkflows.byBot[botKey] = nil end
            end
        end
    end
    -- On a normally completed accept/share, do not clear the final feedback
    -- suppression during CHAT_MSG_WHISPER dispatch. The ChatFrame message filter
    -- runs after Core event handling on legacy clients; clearing here would let
    -- the last correlated reply leak into visible chat. Each matched suppression
    -- removes itself in ShouldSuppressWhisperPresentation, and the TTL remains a
    -- fallback. Abort/timeout/error paths still clear immediately.
    local preserveFeedbackSuppression = reason == "RESPONSES_COMPLETE"
    if self.ClearWhisperPresentationSuppression and not preserveFeedbackSuppression then
        for botKey in pairs(workflow.expected or {}) do self:ClearWhisperPresentationSuppression("QUEST_ACCEPT_FEEDBACK", botKey, reason or "QUEST_ACCEPT_DONE") end
    end
end

local function updateQuestAcceptAggregate(self, tx, workflow)
    local counts = { ACCEPTED = 0, ALREADY_ON = 0, ALREADY_COMPLETED = 0, CANNOT_ACCEPT = 0, NO_RESPONSE = 0, SEND_FAILED = 0, PENDING = 0 }
    local resolved, feedbackCount, bridgeVerifiedCount = 0, 0, 0
    for botKey in pairs(workflow.expected or {}) do
        local outcome = workflow.outcomes[botKey]
        local code = outcome and outcome.code or "PENDING"
        counts[code] = (counts[code] or 0) + 1
        if code ~= "PENDING" then resolved = resolved + 1 end
        if outcome and outcome.correlated == true then feedbackCount = feedbackCount + 1 end
        if outcome and outcome.presenceVerified == true then bridgeVerifiedCount = bridgeVerifiedCount + 1 end
    end
    tx.result = self:Merge(tx.result or {}, {
        questReference = self:Copy(tx.questReference),
        outcomes = self:Copy(workflow.outcomes),
        counts = counts,
        targetCount = workflow.targetCount,
        -- responseCount historically meant "resolved outcomes" in Alpha 1.10;
        -- preserve that field for API compatibility and expose the evidence split separately.
        responseCount = resolved,
        resolvedCount = resolved,
        feedbackCount = feedbackCount,
        bridgeVerifiedCount = bridgeVerifiedCount,
        feedbackComplete = feedbackCount >= workflow.targetCount,
        outcomeComplete = resolved >= workflow.targetCount,
    })
    return counts, resolved
end

local function questAcceptCompletionEvidence(workflow)
    local feedbackCount, bridgeCount = 0, 0
    for botKey in pairs(workflow.expected or {}) do
        local outcome = workflow.outcomes and workflow.outcomes[botKey] or nil
        if outcome and outcome.correlated == true then feedbackCount = feedbackCount + 1 end
        if outcome and outcome.presenceVerified == true then bridgeCount = bridgeCount + 1 end
    end
    if feedbackCount >= workflow.targetCount then return "PLAYERBOTS_ACCEPT_RESPONSES", "PLAYERBOTS_ACCEPT_RESPONSES" end
    if bridgeCount >= workflow.targetCount then return "BRIDGE_QUEST_STATE", "BOT.QUESTS" end
    return "MIXED_PLAYERBOTS_AND_BRIDGE_QUEST_STATE", "MIXED"
end

function MB:VerifyQuestAcceptPresence(txId, botKey)
    local tx = self.transactions and self.transactions[txId] or nil
    if not tx or tx.sessionEpoch ~= self.sessionEpoch then return end
    local outcomes = tx.result and tx.result.outcomes
    local outcome = outcomes and outcomes[botKey]
    if not outcome or (outcome.code ~= "ACCEPTED" and outcome.code ~= "ALREADY_ON") then return end
    local botName = outcome.botName
    self:InvalidateBotDomain("BOT.QUESTS", botKey, "ACTION:QUEST.ACCEPT_LINK")
    self:InvalidateBotDomain("BOT.QUEST_METADATA", botKey, "ACTION:QUEST.ACCEPT_LINK")
    self:After(0.25, function()
        MB:RefreshDomain("BOT.QUESTS", botName, function(snapshot, meta)
            local current = MB.transactions and MB.transactions[txId] or nil
            if not current or current.sessionEpoch ~= MB.sessionEpoch then return end
            local currentOutcomes = current.result and current.result.outcomes
            local record = currentOutcomes and currentOutcomes[botKey]
            if not record then return end
            record.presenceVerified = questPresent(snapshot, current.questReference and current.questReference.questId)
            record.questRevision = meta and meta.revision or nil
            current.result.outcomes[botKey] = record
            local activeWorkflow = MB.questAcceptWorkflows and MB.questAcceptWorkflows.byTx and MB.questAcceptWorkflows.byTx[txId] or nil
            if activeWorkflow and activeWorkflow.outcomes and activeWorkflow.outcomes[botKey] then
                activeWorkflow.outcomes[botKey].presenceVerified = record.presenceVerified
                activeWorkflow.outcomes[botKey].questRevision = record.questRevision
            end
            MB:Emit("MB_ACTION_VERIFICATION_UPDATED", current.id, {
                status = record.presenceVerified and "CONFIRMED" or "UNVERIFIED",
                policy = "BRIDGE_QUEST_PRESENT",
                action = "ACCEPT",
                botKey = botKey, botName = botName, questId = current.questReference and current.questReference.questId, questRevision = record.questRevision,
            }, MB:TransactionSnapshot(current))
        end)
    end)
end

function MB:FinalizeQuestAccept(txId, timedOut, preserveFeedbackSuppression)
    local workflow = self.questAcceptWorkflows and self.questAcceptWorkflows.byTx and self.questAcceptWorkflows.byTx[txId] or nil
    local tx = self.transactions and self.transactions[txId] or nil
    if not workflow or not tx or tx.sessionEpoch ~= self.sessionEpoch then return false end
    if tx.state ~= "DISPATCHING" and tx.state ~= "SENT" and tx.state ~= "SENT_UNVERIFIED" then clearQuestAcceptWorkflow(self, workflow, "TX_NOT_ACTIVE"); return false end

    if timedOut then
        for botKey, expected in pairs(workflow.expected or {}) do
            if not workflow.outcomes[botKey] then
                workflow.outcomes[botKey] = { code = "NO_RESPONSE", botKey = botKey, botName = expected.botName, questId = workflow.questId, receivedAt = self:Now(), correlated = false }
            end
        end
    end

    local counts, resolved = updateQuestAcceptAggregate(self, tx, workflow)
    if resolved < workflow.targetCount and not timedOut then return false end

    tx.completedAt = self:Now()
    tx.result.noResponseCount = counts.NO_RESPONSE or 0
    tx.result.knownOutcomeCount = workflow.targetCount - (counts.NO_RESPONSE or 0)

    if (counts.NO_RESPONSE or 0) == 0 and (counts.SEND_FAILED or 0) == 0 then
        local proof, verifiedBy = questAcceptCompletionEvidence(workflow)
        tx.result.completionProof = proof
        clearQuestAcceptWorkflow(self, workflow, preserveFeedbackSuppression == true and "RESPONSES_COMPLETE" or "VERIFIED_COMPLETE")
        self:SetTransactionState(tx, "CONFIRMED", { verifiedBy = verifiedBy, verifiedAt = self:Now() })
    else
        tx.result.completionProof = timedOut and "PARTIAL_ACCEPT_OUTCOMES" or "PARTIAL_ACCEPT_OUTCOMES"
        clearQuestAcceptWorkflow(self, workflow, timedOut and "TIMEOUT" or "RESPONSES_COMPLETE")
        if tx.state == "DISPATCHING" or tx.state == "SENT" then self:SetTransactionState(tx, "SENT_UNVERIFIED") end
        self:Emit("MB_ACTION_VERIFICATION_UPDATED", tx.id, {
            status = "UNVERIFIED", policy = "QUEST_ACCEPT_OUTCOME", action = "ACCEPT", questId = workflow.questId,
            responseCount = resolved, targetCount = workflow.targetCount, noResponseCount = counts.NO_RESPONSE or 0,
            feedbackCount = tx.result.feedbackCount or 0, bridgeVerifiedCount = tx.result.bridgeVerifiedCount or 0,
        }, self:TransactionSnapshot(tx))
    end
    return true
end

function MB:VerifySilentQuestAcceptTarget(txId, botKey, attempt)
    local workflow = self.questAcceptWorkflows and self.questAcceptWorkflows.byTx and self.questAcceptWorkflows.byTx[txId] or nil
    local tx = self.transactions and self.transactions[txId] or nil
    if not workflow or not tx or tx.sessionEpoch ~= self.sessionEpoch then return false end
    if tx.state ~= "SENT" and tx.state ~= "SENT_UNVERIFIED" then return false end
    if workflow.outcomes and workflow.outcomes[botKey] then return false end
    local precheck = workflow.prechecks and workflow.prechecks[botKey] or nil
    if not precheck or precheck.status ~= "ABSENT" then return false end
    local expected = workflow.expected and workflow.expected[botKey] or nil
    if not expected then return false end

    attempt = tonumber(attempt) or 1
    self:RefreshDomain("BOT.QUESTS", expected.botName, function(snapshot, meta)
        local current = MB.questAcceptWorkflows and MB.questAcceptWorkflows.byTx and MB.questAcceptWorkflows.byTx[txId] or nil
        local currentTx = MB.transactions and MB.transactions[txId] or nil
        if current ~= workflow or not currentTx or currentTx.sessionEpoch ~= MB.sessionEpoch then return end
        if current.outcomes and current.outcomes[botKey] then return end

        local observed = findQuest(snapshot, current.questId)
        if observed then
            local outcome = {
                code = "ACCEPTED", botKey = botKey, botName = expected.botName, questId = current.questId, questName = current.questName,
                receivedAt = MB:Now(), correlated = false, presenceVerified = true,
                proof = "BRIDGE_QUEST_APPEARED_AFTER_SEND", questRevision = meta and meta.revision or nil,
                currentStatus = MB:Upper(observed.status),
            }
            current.outcomes[botKey] = outcome
            updateQuestAcceptAggregate(MB, currentTx, current)
            MB:InvalidateBotDomain("BOT.QUEST_METADATA", botKey, "ACTION:QUEST.ACCEPT_LINK")
            MB:Emit("MB_ACTION_VERIFICATION_UPDATED", currentTx.id, {
                status = "CONFIRMED", policy = "BRIDGE_QUEST_APPEARED_AFTER_SEND", action = "ACCEPT",
                botKey = botKey, botName = expected.botName, questId = current.questId, questRevision = outcome.questRevision,
            }, MB:TransactionSnapshot(currentTx))
            MB:FinalizeQuestAccept(currentTx.id, false)
            return
        end

        if attempt < 3 and MB.questAcceptWorkflows and MB.questAcceptWorkflows.byTx and MB.questAcceptWorkflows.byTx[txId] == current then
            local delays = { [1] = 0.75, [2] = 1.20 }
            MB:After(delays[attempt] or 0.9, function() MB:VerifySilentQuestAcceptTarget(txId, botKey, attempt + 1) end)
        end
    end)
    return true
end

function MB:DispatchQuestAcceptAfterPrecheck(workflow)
    if not workflow then return false end
    local tx = self.transactions and self.transactions[workflow.txId] or nil
    if not tx or tx.sessionEpoch ~= workflow.epoch or tx.state ~= "DISPATCHING" then return false end
    local active = self.questAcceptWorkflows and self.questAcceptWorkflows.byTx and self.questAcceptWorkflows.byTx[workflow.txId] or nil
    if active ~= workflow then return false end

    updateQuestAcceptAggregate(self, tx, workflow)
    local sendTargets = workflow.sendTargets or {}
    if #sendTargets == 0 then
        tx.result = self:Merge(tx.result or {}, { sent = 0, sendFailed = 0, questReference = self:Copy(tx.questReference) })
        tx.completedAt = self:Now()
        self.runtime.counters.actionsCompleted = self.runtime.counters.actionsCompleted + 1
        self:FinalizeQuestAccept(tx.id, false)
        if type(tx.callback) == "function" then self:SafeCall(tx.callback, self:TransactionSnapshot(tx)) end
        return true
    end

    workflow.stage = "SHARE_QUEST_LINK"
    tx.stage = "SHARE_QUEST_LINK"
    tx.sentAt = self:Now()
    for _, bot in ipairs(sendTargets) do
        if self.BeginWhisperPresentationSuppression then self:BeginWhisperPresentationSuppression("QUEST_ACCEPT_FEEDBACK", bot.name, 7) end
    end
    self:SetTransactionState(tx, "SENT")

    local sequence = {}
    for _, bot in ipairs(sendTargets) do sequence[#sequence + 1] = { route = "BOT", bot = bot.name, command = "accept " .. workflow.questLink } end

    local ok, err = self:ChatSendSequence(sequence, function(result)
        local current = MB.questAcceptWorkflows and MB.questAcceptWorkflows.byTx and MB.questAcceptWorkflows.byTx[tx.id] or nil
        local currentTx = MB.transactions and MB.transactions[tx.id] or nil
        if current ~= workflow or not currentTx or currentTx.sessionEpoch ~= workflow.epoch then return end
        currentTx.result = MB:Merge(currentTx.result or {}, { sent = result and result.sent or 0, sendFailed = result and result.failed or 0, questReference = MB:Copy(currentTx.questReference) })
        if result and type(result.errors) == "table" then
            for _, sendErr in ipairs(result.errors) do
                local botKey = sendErr.bot and MB:BotKey(sendErr.bot) or nil
                local expected = botKey and workflow.expected[botKey]
                if expected and not workflow.outcomes[botKey] then workflow.outcomes[botKey] = { code = "SEND_FAILED", botKey = botKey, botName = expected.botName, questId = workflow.questId, error = sendErr.error, receivedAt = MB:Now(), correlated = false } end
            end
        end
        MB.runtime.counters.actionsCompleted = MB.runtime.counters.actionsCompleted + 1
        updateQuestAcceptAggregate(MB, currentTx, workflow)
        if currentTx.state == "SENT" then MB:SetTransactionState(currentTx, "SENT_UNVERIFIED") end
        if type(currentTx.callback) == "function" then MB:SafeCall(currentTx.callback, MB:TransactionSnapshot(currentTx)) end
        MB:FinalizeQuestAccept(currentTx.id, false)
        for _, bot in ipairs(sendTargets) do
            if not workflow.outcomes[bot.key] then
                local key = bot.key
                MB:After(0.35, function() MB:VerifySilentQuestAcceptTarget(currentTx.id, key, 1) end)
            end
        end
    end, function()
        return tx.sessionEpoch == MB.sessionEpoch and (tx.state == "SENT" or tx.state == "SENT_UNVERIFIED") and MB.questAcceptWorkflows.byTx[tx.id] == workflow
    end)
    if not ok then
        clearQuestAcceptWorkflow(self, workflow, err or "QUEST_ACCEPT_SEND_FAILED")
        tx.completedAt = self:Now()
        self.runtime.counters.actionsCompleted = self.runtime.counters.actionsCompleted + 1
        self:SetTransactionState(tx, "FAILED", { error = err or "QUEST_ACCEPT_SEND_FAILED" })
        if type(tx.callback) == "function" then self:SafeCall(tx.callback, self:TransactionSnapshot(tx)) end
        return false
    end

    local txId, epoch = tx.id, tx.sessionEpoch
    self:After(5.5, function()
        local current = MB.transactions and MB.transactions[txId] or nil
        local activeWorkflow = MB.questAcceptWorkflows and MB.questAcceptWorkflows.byTx and MB.questAcceptWorkflows.byTx[txId] or nil
        if current and activeWorkflow == workflow and current.sessionEpoch == epoch and (current.state == "SENT" or current.state == "SENT_UNVERIFIED") then MB:FinalizeQuestAccept(txId, true) end
    end)
    return true
end

function MB:BeginQuestAcceptLink(tx)
    local args = tx and tx.args or {}
    local quest, linkErr = self:ParseQuestLink(args.questLink)
    if not tx or not quest then return false, linkErr or "INVALID_QUEST_LINK" end
    local targets = tx.targets or tx.resolvedTargets or {}
    if #targets == 0 then return false, "NO_TARGETS" end

    self.questAcceptWorkflows = self.questAcceptWorkflows or { byBot = {}, byTx = {} }
    for _, bot in ipairs(targets) do
        local abandon = self.questWorkflows and self.questWorkflows.byBot and self.questWorkflows.byBot[bot.key]
        local metadata = self.questMetadataReads and self.questMetadataReads.byBot and self.questMetadataReads.byBot[bot.key]
        local accept = self.questAcceptWorkflows.byBot and self.questAcceptWorkflows.byBot[bot.key]
        if (abandon and abandon.epoch == self.sessionEpoch) or (metadata and metadata.epoch == self.sessionEpoch) or (accept and accept.epoch == self.sessionEpoch) then return false, "QUEST_CHAT_BUSY" end
    end

    local workflow = {
        txId = tx.id, epoch = self.sessionEpoch, questId = quest.questId, questName = quest.name, questLevel = quest.questLevel, questLink = quest.link,
        expected = {}, outcomes = {}, prechecks = {}, sendTargets = {}, precheckPending = #targets, targetCount = #targets, startedAt = self:Now(), stage = "PRECHECK",
    }
    for _, bot in ipairs(targets) do
        workflow.expected[bot.key] = { botKey = bot.key, botName = bot.name }
        self.questAcceptWorkflows.byBot[bot.key] = workflow
    end
    self.questAcceptWorkflows.byTx[tx.id] = workflow
    tx.questReference = self:Copy(quest)
    tx.stage = "PRECHECK_QUEST_STATE"

    for _, targetBot in ipairs(targets) do
        local bot = targetBot
        self:RefreshDomain("BOT.QUESTS", bot.name, function(snapshot, meta)
            local current = MB.questAcceptWorkflows and MB.questAcceptWorkflows.byTx and MB.questAcceptWorkflows.byTx[tx.id] or nil
            local currentTx = MB.transactions and MB.transactions[tx.id] or nil
            if current ~= workflow or not currentTx or currentTx.sessionEpoch ~= workflow.epoch or currentTx.state ~= "DISPATCHING" then return end
            if workflow.prechecks[bot.key] then return end

            local observed = findQuest(snapshot, workflow.questId)
            local readError = meta and meta.error or nil
            if observed then
                local status = MB:Upper(observed.status)
                local code = status == "C" and "ALREADY_COMPLETED" or "ALREADY_ON"
                workflow.prechecks[bot.key] = { status = "PRESENT", questStatus = status, revision = meta and meta.revision or nil }
                workflow.outcomes[bot.key] = {
                    code = code, botKey = bot.key, botName = bot.name, questId = workflow.questId, questName = workflow.questName,
                    receivedAt = MB:Now(), correlated = false, presenceVerified = true,
                    proof = "BRIDGE_QUEST_PRESENT_BEFORE_SEND", questRevision = meta and meta.revision or nil,
                }
                MB:Emit("MB_ACTION_VERIFICATION_UPDATED", currentTx.id, {
                    status = "CONFIRMED", policy = "BRIDGE_QUEST_PRESENT_BEFORE_SEND", action = "ACCEPT",
                    botKey = bot.key, botName = bot.name, questId = workflow.questId, questRevision = meta and meta.revision or nil,
                }, MB:TransactionSnapshot(currentTx))
            else
                workflow.prechecks[bot.key] = { status = readError and "ERROR" or "ABSENT", error = readError, revision = meta and meta.revision or nil }
                workflow.sendTargets[#workflow.sendTargets + 1] = MB:Copy(bot)
            end
            workflow.precheckPending = math.max(0, (tonumber(workflow.precheckPending) or 1) - 1)
            if workflow.precheckPending == 0 then MB:DispatchQuestAcceptAfterPrecheck(workflow) end
        end)
    end
    return true
end

function MB:HandleQuestAcceptWhisper(message, author)
    local botName = normalizeWhisperAuthor(self, author)
    local botKey = botName and self:BotKey(botName) or nil
    local workflow = botKey and self.questAcceptWorkflows and self.questAcceptWorkflows.byBot and self.questAcceptWorkflows.byBot[botKey] or nil
    if not workflow or workflow.epoch ~= self.sessionEpoch then return false end
    local tx = self.transactions and self.transactions[workflow.txId] or nil
    if not tx or tx.sessionEpoch ~= self.sessionEpoch or (tx.state ~= "SENT" and tx.state ~= "SENT_UNVERIFIED") then return false end

    local code, raw = parseQuestAcceptOutcome(self, message)
    if not code then return false end
    if workflow.outcomes[botKey] then return true end

    local expected = workflow.expected[botKey]
    local outcome = { code = code, botKey = botKey, botName = expected and expected.botName or botName, questId = workflow.questId, questName = workflow.questName, raw = raw, receivedAt = self:Now(), correlated = true }
    workflow.outcomes[botKey] = outcome
    updateQuestAcceptAggregate(self, tx, workflow)

    local feedback = { kind = "QUEST_ACCEPT_RESULT", code = code, outcome = code, raw = raw, author = outcome.botName, botName = outcome.botName, botKey = botKey, questId = workflow.questId, questName = workflow.questName, receivedAt = outcome.receivedAt, correlated = true }
    self:Emit("MB_ACTION_FEEDBACK", tx.id, self:Copy(feedback), self:TransactionSnapshot(tx))
    if code == "ACCEPTED" or code == "ALREADY_ON" then self:VerifyQuestAcceptPresence(tx.id, botKey) end
    self:FinalizeQuestAccept(tx.id, false, true)
    return true
end

function MB:AbortQuestAcceptWorkflows(reason)
    if not (self.questAcceptWorkflows and self.questAcceptWorkflows.byTx) then return 0 end
    local active = {}
    for _, workflow in pairs(self.questAcceptWorkflows.byTx) do active[#active + 1] = workflow end
    for _, workflow in ipairs(active) do clearQuestAcceptWorkflow(self, workflow, reason or "SESSION_RESET") end
    return #active
end

function MB:HandleQuestWhisper(message, author)
    if self.HandleQuestMetadataWhisper and self:HandleQuestMetadataWhisper(message, author) then return true end
    if self.HandleQuestAcceptWhisper and self:HandleQuestAcceptWhisper(message, author) then return true end
    local botName = normalizeWhisperAuthor(self, author)
    local bot = botName and self:ResolveBot(botName) or nil
    if not bot then return false end
    local workflow = self.questWorkflows and self.questWorkflows.byBot and self.questWorkflows.byBot[bot.key] or nil
    if not workflow or workflow.epoch ~= self.sessionEpoch then return false end
    local tx = self.transactions and self.transactions[workflow.txId] or nil
    if not tx or tx.sessionEpoch ~= self.sessionEpoch then clearWorkflow(self, workflow, "STALE"); return false end

    if workflow.stage == "RESOLVE_LINK" and tx.state == "DISPATCHING" then
        local link, questLevel, linkSource = extractExactQuestLink(message, workflow.questId)
        if link then
            self:DispatchResolvedQuestAbandon(workflow, link, questLevel, linkSource)
            return true
        end
    elseif workflow.stage == "VERIFY" and tx.state == "SENT_UNVERIFIED" then
        local text = self:Trim(message or "")
        if string.sub(self:Lower(text), 1, 13) == "quest removed" then
            local feedback = { kind = "ACCEPTED", code = "QUEST_REMOVED", raw = text, author = bot.name, receivedAt = self:Now(), correlated = true }
            tx.result = self:Merge(tx.result or {}, { feedback = self:Copy(feedback) })
            self:Emit("MB_ACTION_FEEDBACK", tx.id, self:Copy(feedback), self:TransactionSnapshot(tx))
            return true
        end
    end
    return false
end

function MB:AbortQuestWorkflows(reason)
    if not (self.questWorkflows and self.questWorkflows.byBot) then return 0 end
    local workflows = {}
    for _, workflow in pairs(self.questWorkflows.byBot) do workflows[#workflows + 1] = workflow end
    for _, workflow in ipairs(workflows) do clearWorkflow(self, workflow, reason or "SESSION_RESET") end
    return #workflows
end
