local _, MB = ...

MB.API = MB.API or {}
local API = MB.API

function MB:GetAPI(requiredVersion)
    requiredVersion = tonumber(requiredVersion) or self.API_VERSION
    if requiredVersion > self.API_VERSION then return nil, "API_VERSION_UNAVAILABLE" end
    return API
end

function API:GetVersion() return MB.API_VERSION end
function API:GetCoreVersion() return MB.version end
function API:IsReady() return MB.initialized == true end
function API:IsBridgeReady() return MB.bridge.connected == true and MB.bridge.handshakeReady == true and MB.bridge.protocol ~= nil and MB.bridge.protocol ~= "" end
function API:IsBotRegistryReady() return MB.botRegistryReady == true and MB.botRegistryReadyEpoch == MB.sessionEpoch end

function API:RegisterModule(moduleName, metadata) return MB:RegisterModule(moduleName, metadata) end
function API:UnregisterModule(moduleName) return MB:UnregisterModule(moduleName) end
function API:GetRegisteredModules() return MB:Copy(MB.modules) end
function API:RegisterService(moduleName, serviceName, serviceObject, options) return MB:RegisterService(moduleName, serviceName, serviceObject, options) end
function API:GetService(serviceName) return MB:GetService(serviceName) end

function API:RegisterContextAction(moduleName, descriptor) return MB:RegisterContextAction(moduleName, descriptor) end
function API:UnregisterContextAction(moduleName, actionId) return MB:UnregisterContextAction(moduleName, actionId) end
function API:GetContextActions(contextType, contextData) return MB:GetContextActions(contextType, contextData) end
function API:GetContextTree(contextType, contextData) return MB:GetContextTree(contextType, contextData) end
function API:InvokeContextAction(contributionId, contextData, ...) return MB:InvokeContextAction(contributionId, contextData, ...) end

function API:GetBots(filter) return MB:GetBots(filter) end
function API:GetBot(ref) local bot = MB:ResolveBot(ref); return bot and MB:Copy(bot) or nil end
function API:ResolveBot(ref) return API:GetBot(ref) end
function API:Select(selector) return MB:ResolveSelection(selector) end
function API:SetSelection(name, refs) return MB:SetSelection(name, refs) end
function API:GetSelection(name) return MB:GetSelection(name) end
function API:AddSelection(name, ref) return MB:AddSelection(name, ref) end
function API:RemoveSelection(name, ref) return MB:RemoveSelection(name, ref) end
function API:ToggleSelection(name, ref) return MB:ToggleSelection(name, ref) end
function API:ClearSelection(name) return MB:ClearSelection(name) end
function API:SaveSelection(name, source, options) return MB:SaveSelection(name, source, options) end
function API:GetSavedSelection(name) return MB:GetSavedSelection(name) end
function API:GetSavedSelections() return MB:GetSavedSelections() end
function API:AddToSavedSelection(name, targetSpec) return MB:AddToSavedSelection(name, targetSpec) end
function API:RemoveFromSavedSelection(name, targetSpec) return MB:RemoveFromSavedSelection(name, targetSpec) end
function API:ToggleSavedSelectionMember(name, botRef) return MB:ToggleSavedSelectionMember(name, botRef) end
function API:DeleteSavedSelection(name) return MB:DeleteSavedSelection(name) end
function API:LoadSavedSelection(name, workingName) return MB:LoadSavedSelection(name, workingName) end
function API:ResolveSelection(selector) return MB:ResolveSelection(selector) end
function API:ResolveTargetSpec(targetSpec) return MB:ResolveTargetSpec(targetSpec) end
function API:GetTargetCatalog() return MB:GetTargetCatalog() end
function API:GetBotRole(ref) return MB:GetBotRole(ref) end
function API:GetBotSpec(ref) return MB:GetBotSpec(ref) end
function API:GetBotRange(ref) return MB:GetBotRange(ref) end
function API:GetBotSubgroup(ref) return MB:GetBotSubgroup(ref) end

-- Structured premade talent-spec mutation. Core validates the selected spec
-- against a fresh BOT.TALENT_SPECS response immediately before dispatch.
function API:GetTalentSpecApplyAvailability(botRef, specIndex, options) return MB:GetTalentSpecApplyAvailability(botRef, specIndex, options) end
function API:ApplyTalentSpec(originModule, botRef, specIndex, options, callback) return MB:ApplyTalentSpec(originModule, botRef, specIndex, options, callback) end
function API:GetTalentView(botRef) return MB:GetTalentView(botRef) end
function API:GetTalentObservationAvailability(botRef, options) return MB:GetTalentObservationAvailability(botRef, options) end
function API:GetTalentObservationCapabilities(botRef) return MB:GetTalentObservationCapabilities(botRef) end

-- Narrow spell compatibility semantics. No generic Playerbots chat passthrough is exposed.
function API:GetBotSpellEnabled(botRef, spellId) return MB:GetBotSpellEnabled(botRef, spellId) end
function API:GetBotSpellEnabledAvailability(botRef, spellId) return MB:GetBotSpellEnabledAvailability(botRef, spellId) end
function API:SetBotSpellEnabled(originModule, botRef, spellId, enabled, callback) return MB:SetBotSpellEnabled(originModule, botRef, spellId, enabled, callback) end
function API:GetBotSpellCastAvailability(botRef, spellId, options) return MB:GetBotSpellCastAvailability(botRef, spellId, options) end
function API:CastBotSpell(originModule, botRef, spellId, options, callback) return MB:CastBotSpell(originModule, botRef, spellId, options, callback) end
function API:GetBotSpellActionContract(botRef, spellId) return MB:GetBotSpellActionContract(botRef, spellId) end

function API:Acquire(moduleName, domainId, target, options) return MB:AcquireInterest(moduleName, domainId, target, options) end
function API:Release(moduleName, domainId, target) return MB:ReleaseInterest(moduleName, domainId, target) end
function API:Get(domainId, target) return MB:GetData(domainId, target) end
function API:GetMeta(domainId, target) return MB:GetDataMeta(domainId, target) end
function API:Refresh(domainId, target, callback, options) return MB:RefreshDomain(domainId, target, callback, options) end

-- Explicit historical/display-only access. These methods never participate in
-- canonical live reads, action preflight, transaction verification, or mutations.
function API:GetLastKnown(domainId, botRef) return MB:GetLastKnown(domainId, botRef) end
function API:GetLastKnownMeta(domainId, botRef) return MB:GetLastKnownMeta(domainId, botRef) end
function API:HasLastKnown(domainId, botRef) return MB:HasLastKnown(domainId, botRef) end
function API:GetLastKnownDomains(botRef) return MB:GetLastKnownDomains(botRef) end

function API:GetAltRosterView() return MB:GetAltRosterView() end
function API:GetManagedRosterView() return MB:GetManagedRosterView() end
function API:GetManagedBot(botRef) return MB:GetManagedBot(botRef) end
function API:GetForgetManagedBotAvailability(botRef) return MB:GetForgetManagedBotAvailability(botRef) end
function API:ForgetManagedBot(originModule, botRef, options, callback) return MB:ForgetManagedBot(originModule, botRef, options, callback) end
function API:GetManagedGroups() return MB:GetManagedGroups() end
function API:GetManagedGroup(groupRef) return MB:GetManagedGroup(groupRef) end
function API:CreateManagedGroup(name) return MB:CreateManagedGroup(name) end
function API:RenameManagedGroup(groupRef, newName) return MB:RenameManagedGroup(groupRef, newName) end
function API:DeleteManagedGroup(groupRef) return MB:DeleteManagedGroup(groupRef) end
function API:AddManagedGroupMember(groupRef, botRef) return MB:AddManagedGroupMember(groupRef, botRef) end
function API:RemoveManagedGroupMember(groupRef, botRef) return MB:RemoveManagedGroupMember(groupRef, botRef) end
function API:GetManagedGroupLifecycleAvailability(groupRef, action, options) return MB:GetManagedGroupLifecycleAvailability(groupRef, action, options) end
function API:GetManagedGroupLifecycleContract() return MB:GetManagedGroupLifecycleContract() end
function API:RequestManagedGroupLifecycle(originModule, groupRef, action, callback, options) return MB:RequestManagedGroupLifecycle(originModule, groupRef, action, callback, options) end
function API:GetManagedGroupLifecycleRequest(requestId) return MB:GetManagedGroupLifecycleRequest(requestId) end
function API:GetManagedGroupLifecycleRequests() return MB:GetManagedGroupLifecycleRequests() end
function API:GetLifecycleTargetView(botRef) return MB:GetLifecycleTargetView(botRef) end
function API:ResolveBotTarget(botRef, callback) return MB:ResolveBotTarget(botRef, callback) end
function API:GetBotLifecycleAvailability(botRef, action) return MB:GetBotLifecycleAvailability(botRef, action) end
function API:GetManagedBotLifecycleAvailability(botRef, action) return MB:GetManagedLifecycleAvailability(botRef, action) end
function API:GetBotLifecycleContract() return MB:GetBotLifecycleContract() end
function API:ExecuteBotLifecycle(originModule, botRef, action, callback) return MB:ExecuteBotLifecycle(originModule, botRef, action, callback) end
function API:RequestBotLifecycle(originModule, botRef, action, callback) return MB:RequestBotLifecycle(originModule, botRef, action, callback) end

function API:RegisterSnapshotProvider(moduleName, providerId, descriptor) return MB:RegisterSnapshotProvider(moduleName, providerId, descriptor) end
function API:UnregisterSnapshotProvider(moduleName, providerId) return MB:UnregisterSnapshotProvider(moduleName, providerId) end
function API:GetSnapshotProviders() return MB:GetSnapshotProviders() end
function API:GetSnapshotProfile(profileName) return MB:GetSnapshotProfile(profileName) end
function API:GetSnapshotRefreshAvailability(botRef, options) return MB:GetSnapshotRefreshAvailability(botRef, options) end
function API:RequestBotSnapshot(botRef, callback, options) return MB:RequestBotSnapshot(botRef, callback, options) end
function API:GetBotSnapshot(botRef) return MB:GetBotSnapshot(botRef) end
function API:GetBotSnapshots() return MB:GetBotSnapshots() end
function API:GetBotSnapshotStatus(botRef) return MB:GetBotSnapshotStatus(botRef) end

function API:GetInventoryView(botRef) return MB:GetInventoryView(botRef) end
function API:GetInventoryExactView(botRef) return MB:GetInventoryExactView(botRef) end
function API:GetBuybackView(botRef) return MB:GetBuybackView(botRef) end
function API:GetInventoryLayout(botRef) return MB:GetInventoryLayout(botRef) end
function API:FindInventoryItems(botRef, query) return MB:FindInventoryItems(botRef, query) end
function API:GetInventoryItemCount(botRef, itemId) return MB:GetInventoryItemCount(botRef, itemId) end
function API:GetInventorySummary(botRef) return MB:GetInventorySummary(botRef) end
function API:ResolveInventoryItem(botRef, selector) return MB:ResolveInventoryItem(botRef, selector) end
function API:GetInventoryEquipmentCandidates(botRef, query) return MB:GetInventoryEquipmentCandidates(botRef, query) end
function API:GetInventoryIndex(botRef) return MB:GetInventoryIndex(botRef) end
function API:GetInventoryCapabilities(botRef) return MB:GetInventoryCapabilities(botRef) end
function API:GetEquipmentView(botRef) return MB:GetEquipmentView(botRef) end
function API:GetEquipmentSlotMap() return MB:GetEquipmentSlotMap() end
function API:GetEquipmentObservationAvailability(botRef) return MB:GetEquipmentObservationAvailability(botRef) end
function API:GetEquipmentObservationCapabilities(botRef) return MB:GetEquipmentObservationCapabilities(botRef) end
function API:GetInventoryActionAvailability(botRef, action, selector, options) return MB:GetInventoryActionAvailability(botRef, action, selector, options) end
function API:GetInventoryInteractionContract(action) return MB:GetInventoryInteractionContract(action) end
function API:ExecuteInventoryAction(originModule, botRef, action, selector, options, callback) return MB:ExecuteInventoryAction(originModule, botRef, action, selector, options, callback) end
function API:GetInventoryMoveAvailability(botRef, sourceBag, sourceSlot, destinationBag, destinationSlot) return MB:GetInventoryMoveAvailability(botRef, sourceBag, sourceSlot, destinationBag, destinationSlot) end
function API:ExecuteInventoryMove(originModule, botRef, sourceBag, sourceSlot, destinationBag, destinationSlot, callback) return MB:ExecuteInventoryMove(originModule, botRef, sourceBag, sourceSlot, destinationBag, destinationSlot, callback) end
function API:GetInventoryUnequipAvailability(botRef, equipmentSlot, itemId) return MB:GetInventoryUnequipAvailability(botRef, equipmentSlot, itemId) end
function API:ExecuteInventoryUnequip(originModule, botRef, equipmentSlot, itemId, callback) return MB:ExecuteInventoryUnequip(originModule, botRef, equipmentSlot, itemId, callback) end
function API:GetBuybackAvailability(botRef, selector) return MB:GetBuybackAvailability(botRef, selector) end
function API:ExecuteBuyback(originModule, botRef, selector, callback) return MB:ExecuteBuyback(originModule, botRef, selector, callback) end

function API:GetStorageView(botRef, kind) return MB:GetStorageView(botRef, kind) end
function API:GetBankView(botRef) return MB:GetBankView(botRef) end
function API:GetGuildBankView(botRef) return MB:GetGuildBankView(botRef) end

function API:GetQuestNpcActionAvailability(botRef, kind, options)
    local actionId = MB:Upper(kind) == "TALK_TARGET" and "QUEST.TALK_TARGET"
        or (MB:Upper(kind) == "ACCEPT_NEARBY" and "QUEST.ACCEPT_NEARBY" or nil)
    if not actionId then return { enabled = false, reason = "INVALID_QUEST_NPC_ACTION" } end
    local args = { confirmed = type(options) == "table" and options.confirmed == true }
    return MB:GetActionAvailability(actionId, botRef, args)
end
function API:ExecuteQuestNpcAction(originModule, botRef, kind, options, callback)
    local actionId = MB:Upper(kind) == "TALK_TARGET" and "QUEST.TALK_TARGET"
        or (MB:Upper(kind) == "ACCEPT_NEARBY" and "QUEST.ACCEPT_NEARBY" or nil)
    if not actionId then return nil, "INVALID_QUEST_NPC_ACTION" end
    local args = { confirmed = type(options) == "table" and options.confirmed == true }
    return MB:ExecuteAction(originModule, actionId, botRef, args, callback)
end
function API:GetQuestView(botRef) return MB:GetQuestView(botRef) end
function API:ParseQuestLink(link) return MB:ParseQuestLink(link) end
function API:GetQuestMetadata(botRef) return MB:GetQuestMetadata(botRef) end
function API:RefreshQuestMetadata(botRef, callback, options) return MB:RefreshQuestMetadata(botRef, callback, options) end
function API:FindQuests(botRef, query) return MB:FindQuests(botRef, query) end
function API:ResolveQuest(botRef, selector) return MB:ResolveQuest(botRef, selector) end
function API:GetQuestCapabilities(botRef) return MB:GetQuestCapabilities(botRef) end
function API:GetQuestActionAvailability(botRef, action, selector, options) return MB:GetQuestActionAvailability(botRef, action, selector, options) end
function API:GetQuestInteractionContract(action) return MB:GetQuestInteractionContract(action) end
function API:ExecuteQuestAction(originModule, botRef, action, selector, options, callback) return MB:ExecuteQuestAction(originModule, botRef, action, selector, options, callback) end

function API:GetRTIIcons() return MB:GetRTIIcons() end
function API:GetRTIAssignment(botRef, purpose) return MB:GetRTIAssignment(botRef, purpose) end
function API:GetRTIAssignmentSummary() return MB:GetRTIAssignmentSummary() end
function API:PreviewRTIAssignment(targetSpec, purpose, icon) return MB:PreviewRTIAssignment(targetSpec, purpose, icon) end
function API:AssignRTI(originModule, targetSpec, purpose, icon, callback) return MB:AssignRTI(originModule, targetSpec, purpose, icon, callback) end
function API:RunAssignedRTI(originModule, targetSpec, mode, callback) return MB:RunAssignedRTI(originModule, targetSpec, mode, callback) end

function API:OrderBots(originModule, targetSpec, order, callback) return MB:OrderBots(originModule, targetSpec, order, callback) end

function API:GetRTSCPlacementContract() return MB:GetRTSCPlacementContract() end
function API:EnableRTSC(originModule, callback) return MB:EnableRTSC(originModule, callback) end
function API:PrepareRTSCPlacement(originModule, targetSpec, slot, callback) return MB:PrepareRTSCPlacement(originModule, targetSpec, slot, callback) end
function API:SelectRTSCTargets(originModule, targetSpec, callback) return MB:SelectRTSCTargets(originModule, targetSpec, callback) end
function API:GoRTSCLocation(originModule, targetSpec, slot, callback) return MB:GoRTSCLocation(originModule, targetSpec, slot, callback) end
function API:SaveRTSCLocation(originModule, slot, callback) return MB:SaveRTSCLocation(originModule, slot, callback) end
function API:ArmRTSCLocationImmediate(originModule, slot, clearFirst) return MB:ArmRTSCLocationImmediate(originModule, slot, clearFirst) end
function API:UnsaveRTSCLocation(originModule, slot, callback) return MB:UnsaveRTSCLocation(originModule, slot, callback) end
function API:CancelRTSC(originModule, callback) return MB:CancelRTSC(originModule, callback) end
function API:RTSCStrategies(originModule, targetSpec, enabled, callback) return MB:RTSCStrategies(originModule, targetSpec, enabled, callback) end

function API:Subscribe(moduleName, eventName, callback)
    if not MB.modules[moduleName] then MB:RegisterModule(moduleName) end
    return MB:Subscribe(moduleName, eventName, callback)
end
function API:Unsubscribe(token) return MB:Unsubscribe(token) end

function API:CanExecute(actionId, targetSpec, args) return MB:CanExecuteAction(actionId, targetSpec, args) end
function API:GetActionAvailability(actionId, targetSpec, args) return MB:GetActionAvailability(actionId, targetSpec, args) end
function API:Execute(originModule, actionId, targetSpec, args, callback) return MB:ExecuteAction(originModule, actionId, targetSpec, args, callback) end
function API:ExecuteSet(originModule, actionId, selector, args, callback) return MB:ExecuteActionSet(originModule, actionId, selector, args, callback) end
function API:GetTransaction(id) return MB:GetTransaction(id) end

function API:GetCapabilities() return MB:Copy(MB.bridge.capabilities or {}) end
function API:HasCapability(capability) return MB:BridgeHasCapability(capability) end
function API:GetActionDescriptor(id) return MB:GetActionDescriptor(id) end
function API:GetDomainDescriptor(id) return MB:GetDomainDescriptor(id) end

function API:GetManifest()
    local domains, actions, events, contextTypes = {}, {}, {}, {}
    for id in pairs(MB.dataDomains) do domains[#domains + 1] = id end
    for id in pairs(MB.actions) do actions[#actions + 1] = id end
    for _, name in ipairs(MB.PUBLIC_EVENTS) do events[#events + 1] = name end
    local seen = {}
    for _, descriptor in pairs(MB.contextActions) do
        if type(descriptor.contexts) == "string" then seen[descriptor.contexts] = true
        elseif type(descriptor.contexts) == "table" then
            for k, v in pairs(descriptor.contexts) do
                if type(k) == "number" then seen[tostring(v)] = true elseif v == true then seen[tostring(k)] = true end
            end
        end
    end
    for contextType in pairs(seen) do contextTypes[#contextTypes + 1] = contextType end
    table.sort(domains); table.sort(actions); table.sort(events); table.sort(contextTypes)
    return {
        coreVersion = MB.version, apiVersion = MB.API_VERSION, bridgePrefix = MB.BRIDGE_PREFIX,
        bridgeProtocol = MB.bridge.protocol, bridgeServer = MB.bridge.server, bridgeConnected = MB.bridge.connected, bridgeReady = API:IsBridgeReady(),
        bridgeCapabilities = MB:Copy(MB.bridge.capabilities), observedProtocolExtensions = MB:Copy(MB.bridge.observedExtensions),
        domains = domains, actions = actions, events = events, contextTypes = contextTypes,
        modules = MB:Copy(MB.modules), sessionEpoch = MB.sessionEpoch, botRegistryReady = API:IsBotRegistryReady(),
    }
end
