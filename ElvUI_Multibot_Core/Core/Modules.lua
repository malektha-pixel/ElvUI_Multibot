local _, MB = ...

local function contextMatches(descriptor, contextType)
    local contexts = descriptor.contexts
    if type(contexts) == "string" then return contexts == contextType end
    if type(contexts) ~= "table" then return false end
    if contexts[contextType] == true then return true end
    for _, value in ipairs(contexts) do if value == contextType then return true end end
    return false
end

local function requirementCapabilities(self, capabilities)
    if type(capabilities) == "string" then capabilities = { capabilities } end
    if type(capabilities) ~= "table" then return true end
    for key, value in pairs(capabilities) do
        local capability = type(key) == "number" and value or key
        local required = type(key) == "number" and true or value == true
        if required and not self:BridgeHasCapability(tostring(capability)) then
            return false, "CAPABILITY_UNAVAILABLE:" .. tostring(capability)
        end
    end
    return true
end

local function checkRequirements(self, descriptor, contextData)
    local requirements = descriptor.requirements
    if type(requirements) ~= "table" then return true end
    if requirements.bridgeReady == true and not (self.bridge.connected and self.bridge.handshakeReady) then return false, "BRIDGE_NOT_READY" end
    if requirements.botRegistryReady == true and not (self.botRegistryReady and self.botRegistryReadyEpoch == self.sessionEpoch) then return false, "BOT_REGISTRY_NOT_READY" end
    if requirements.bot == true then
        local ref = contextData and (contextData.bot or contextData.botName or contextData.botKey or contextData.target)
        if not ref or not self:ResolveBot(ref) then return false, "BOT_UNAVAILABLE" end
    end
    local ok, reason = requirementCapabilities(self, requirements.capabilities)
    if not ok then return false, reason end
    return true
end

local function resolveCoreAction(self, descriptor, contextData)
    local binding = descriptor.coreAction
    if type(binding) ~= "table" then return nil end
    local actionId = self:Trim(binding.id)
    if actionId == "" then return nil, "CORE_ACTION_ID_REQUIRED" end

    local target = binding.target
    if type(target) == "function" then
        local ok, value = pcall(target, contextData)
        if not ok then return nil, tostring(value) end
        target = value
    elseif target == nil then
        target = contextData and (contextData.bot or contextData.botName or contextData.target) or nil
    end

    local args = binding.args
    if type(args) == "function" then
        local ok, value = pcall(args, contextData)
        if not ok then return nil, tostring(value) end
        args = value
    end
    if type(args) ~= "table" then args = {} else args = self:Copy(args) end

    local availability = self:GetActionAvailability(actionId, target, args)
    return { actionId = actionId, target = target, args = args, availability = availability }
end

local function evaluateEnabled(self, descriptor, contextData, contextType)
    local ok, reason = checkRequirements(self, descriptor, contextData)
    if not ok then return false, reason end

    if type(descriptor.enabled) == "function" then
        local callOk, result, detail = pcall(descriptor.enabled, contextData, contextType)
        if not callOk then return false, tostring(result) end
        if result == false then return false, detail or "CONTEXT_ACTION_DISABLED" end
    elseif descriptor.enabled == false then
        return false, "CONTEXT_ACTION_DISABLED"
    end

    if descriptor.coreAction then
        local resolved, resolveError = resolveCoreAction(self, descriptor, contextData)
        if not resolved then return false, resolveError or "CORE_ACTION_UNAVAILABLE" end
        if not resolved.availability or resolved.availability.enabled ~= true then
            return false, resolved.availability and resolved.availability.reason or "CORE_ACTION_UNAVAILABLE", resolved
        end
        return true, nil, resolved
    end
    return true
end

function MB:RegisterModule(moduleName, metadata)
    moduleName = self:Trim(moduleName)
    if moduleName == "" then return false, "INVALID_MODULE_NAME" end
    local first = self.modules[moduleName] == nil
    local entry = self:Merge(self.modules[moduleName] or {}, metadata or {})
    entry.name = moduleName
    entry.registeredAt = entry.registeredAt or self:Now()
    entry.lastRegisteredAt = self:Now()
    self.modules[moduleName] = entry
    if first then self:Emit("MB_MODULE_REGISTERED", moduleName, self:Copy(entry)) end
    self:Emit("MB_REGISTRY_CHANGED", "MODULE", moduleName)
    return true
end

function MB:UnregisterModule(moduleName)
    moduleName = self:Trim(moduleName)
    if not self.modules[moduleName] then return false end
    if self.ReleaseModuleInterests then self:ReleaseModuleInterests(moduleName) end
    if self.ClearModuleSnapshotProviders then self:ClearModuleSnapshotProviders(moduleName) end
    if self.AbortManagedGroupLifecycleRequests then self:AbortManagedGroupLifecycleRequests("MODULE_UNREGISTERED", moduleName) end
    self:UnsubscribeModule(moduleName)
    self:ClearModuleContextActions(moduleName)
    for serviceName, service in pairs(self.services) do
        if service.owner == moduleName then self.services[serviceName] = nil end
    end
    self.modules[moduleName] = nil
    self:Emit("MB_MODULE_UNREGISTERED", moduleName)
    self:Emit("MB_REGISTRY_CHANGED", "MODULE", moduleName)
    return true
end

function MB:RegisterService(moduleName, serviceName, serviceObject, options)
    moduleName, serviceName = self:Trim(moduleName), self:Trim(serviceName)
    if moduleName == "" or serviceName == "" or type(serviceObject) ~= "table" then return false, "INVALID_SERVICE" end
    if not self.modules[moduleName] then self:RegisterModule(moduleName) end
    local current = self.services[serviceName]
    if current and current.owner ~= moduleName and not (options and options.replace == true) then return false, "SERVICE_ALREADY_REGISTERED" end
    self.services[serviceName] = { owner = moduleName, value = serviceObject, registeredAt = self:Now() }
    self:Emit("MB_REGISTRY_CHANGED", "SERVICE", serviceName)
    return true
end

function MB:GetService(serviceName)
    local entry = self.services[self:Trim(serviceName)]
    return entry and entry.value or nil, entry and entry.owner or nil
end

function MB:RegisterContextAction(moduleName, descriptor)
    moduleName = self:Trim(moduleName)
    if moduleName == "" or type(descriptor) ~= "table" then return nil, "INVALID_CONTEXT_ACTION" end
    if not self.modules[moduleName] then self:RegisterModule(moduleName) end
    local id = self:Trim(descriptor.id)
    if id == "" then return nil, "MISSING_ACTION_ID" end
    local contexts = descriptor.contexts or descriptor.context
    if type(contexts) ~= "table" and type(contexts) ~= "string" then return nil, "MISSING_CONTEXT" end
    local hasHandler = type(descriptor.handler) == "function"
    local hasCoreAction = type(descriptor.coreAction) == "table" and self:Trim(descriptor.coreAction.id) ~= ""
    if not hasHandler and not hasCoreAction then return nil, "MISSING_HANDLER" end
    if hasHandler and hasCoreAction then return nil, "MULTIPLE_EXECUTION_PATHS" end

    local key = moduleName .. ":" .. id
    local copy = self:Copy(descriptor)
    copy.id = id
    copy.moduleName = moduleName
    copy.contexts = contexts
    copy.label = self:Trim(copy.label ~= nil and copy.label or id)
    copy.category = self:Trim(copy.category)
    copy.path = type(copy.path) == "table" and copy.path or nil
    copy.order = tonumber(copy.order) or 100
    copy.registeredAt = self:Now()
    copy.handler = descriptor.handler
    copy.predicate = descriptor.predicate
    copy.enabled = descriptor.enabled
    copy.requirements = self:Copy(descriptor.requirements)
    copy.coreAction = self:Copy(descriptor.coreAction)
    if copy.coreAction then
        copy.coreAction.target = descriptor.coreAction.target
        copy.coreAction.args = descriptor.coreAction.args
    end
    self.contextActions[key] = copy
    self.contextActionByModule[moduleName] = self.contextActionByModule[moduleName] or {}
    self.contextActionByModule[moduleName][key] = true
    self:Emit("MB_REGISTRY_CHANGED", "CONTEXT_ACTION", key)
    return key
end

function MB:UnregisterContextAction(moduleName, actionId)
    local key = self:Trim(moduleName) .. ":" .. self:Trim(actionId)
    if not self.contextActions[key] then return false end
    self.contextActions[key] = nil
    if self.contextActionByModule[moduleName] then self.contextActionByModule[moduleName][key] = nil end
    self:Emit("MB_REGISTRY_CHANGED", "CONTEXT_ACTION", key)
    return true
end

function MB:ClearModuleContextActions(moduleName)
    local bucket = self.contextActionByModule[moduleName]
    if not bucket then return end
    for key in pairs(bucket) do self.contextActions[key] = nil end
    self.contextActionByModule[moduleName] = nil
    self:Emit("MB_REGISTRY_CHANGED", "CONTEXT_ACTIONS", moduleName)
end

function MB:GetContextActions(contextType, contextData)
    contextType = self:Trim(contextType)
    local out = {}
    for key, descriptor in pairs(self.contextActions) do
        if contextMatches(descriptor, contextType) then
            local include = true
            if type(descriptor.predicate) == "function" then
                local ok, result = pcall(descriptor.predicate, contextData, contextType)
                include = ok and result ~= false
                if not ok then self:Log("ERROR", "Context predicate failed for %s: %s", key, tostring(result)) end
            end
            if include then
                local enabled, disabledReason, resolvedCoreAction = evaluateEnabled(self, descriptor, contextData, contextType)
                local public = self:Copy(descriptor)
                public.handler, public.predicate, public.enabled = nil, nil, enabled
                public.disabledReason = disabledReason
                public.contributionId = key
                if descriptor.coreAction then
                    public.coreAction = {
                        id = descriptor.coreAction.id,
                        availability = resolvedCoreAction and self:Copy(resolvedCoreAction.availability) or nil,
                    }
                end
                out[#out + 1] = public
            end
        end
    end
    table.sort(out, function(a, b)
        if (a.order or 100) ~= (b.order or 100) then return (a.order or 100) < (b.order or 100) end
        if (a.category or "") ~= (b.category or "") then return (a.category or "") < (b.category or "") end
        return (a.label or "") < (b.label or "")
    end)
    return out
end

local function findChild(children, id)
    for _, child in ipairs(children) do if child.type == "group" and child.id == id then return child end end
end

function MB:GetContextTree(contextType, contextData)
    local root = { type = "root", id = contextType, children = {} }
    for _, action in ipairs(self:GetContextActions(contextType, contextData)) do
        local node = root
        local path = {}
        if action.path then
            for _, part in ipairs(action.path) do path[#path + 1] = tostring(part) end
        elseif action.category ~= "" then
            path[1] = action.category
        end
        for _, part in ipairs(path) do
            local child = findChild(node.children, part)
            if not child then
                child = { type = "group", id = part, label = part, children = {} }
                node.children[#node.children + 1] = child
            end
            node = child
        end
        node.children[#node.children + 1] = {
            type = "action",
            id = action.id,
            contributionId = action.contributionId,
            moduleName = action.moduleName,
            label = action.label,
            order = action.order,
            enabled = action.enabled,
            disabledReason = action.disabledReason,
            metadata = action.metadata,
            requirements = action.requirements,
            coreAction = action.coreAction,
        }
    end
    return root
end

function MB:InvokeContextAction(contributionId, contextData, ...)
    local descriptor = self.contextActions[self:Trim(contributionId)]
    if not descriptor then return false, "CONTEXT_ACTION_NOT_FOUND" end

    local enabled, reason, resolvedCoreAction = evaluateEnabled(self, descriptor, contextData, nil)
    if not enabled then return false, reason or "CONTEXT_ACTION_DISABLED" end

    if descriptor.coreAction then
        if not resolvedCoreAction then
            resolvedCoreAction, reason = resolveCoreAction(self, descriptor, contextData)
            if not resolvedCoreAction then return false, reason or "CORE_ACTION_UNAVAILABLE" end
        end
        local txId, executeError = self:ExecuteAction(descriptor.moduleName, resolvedCoreAction.actionId, resolvedCoreAction.target, resolvedCoreAction.args)
        if not txId then return false, executeError end
        return true, txId
    end

    local ok, a, b, c = pcall(descriptor.handler, contextData, ...)
    if not ok then
        self:Log("ERROR", "Context action %s failed: %s", contributionId, tostring(a))
        return false, a
    end
    return true, a, b, c
end
