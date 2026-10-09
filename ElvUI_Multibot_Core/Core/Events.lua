local _, MB = ...

MB.PUBLIC_EVENTS = {
    "MB_CORE_READY",
    "MB_SESSION_CHANGED",
    "MB_BRIDGE_STATUS_CHANGED",
    "MB_BRIDGE_READY",
    "MB_BRIDGE_CAPABILITIES_CHANGED",
    "MB_BOT_REGISTRY_READY",
    "MB_BOT_DISCOVERED",
    "MB_BOT_PRESENCE_CHANGED",
    "MB_BOT_LIFECYCLE_UPDATED",
    "MB_MANAGED_ROSTER_UPDATED",
    "MB_MANAGED_BOT_FORGOTTEN",
    "MB_MANAGED_AUTH_UPDATED",
    "MB_MANAGED_GROUP_UPDATED",
    "MB_MANAGED_GROUP_DELETED",
    "MB_MANAGED_GROUP_LIFECYCLE_STARTED",
    "MB_MANAGED_GROUP_LIFECYCLE_PROGRESS",
    "MB_MANAGED_GROUP_LIFECYCLE_RESULT",
    "MB_BOT_LIFECYCLE_REQUEST_RESULT",
    "MB_SNAPSHOT_STARTED",
    "MB_SNAPSHOT_PROGRESS",
    "MB_SNAPSHOT_UPDATED",
    "MB_SNAPSHOT_RESULT",
    "MB_DATA_UPDATED",
    "MB_DATA_CHANGED",
    "MB_DATA_INVALIDATED",
    "MB_DATA_ERROR",
    "MB_SELECTION_CHANGED",
    "MB_SAVED_SELECTION_CREATED",
    "MB_SAVED_SELECTION_CHANGED",
    "MB_SAVED_SELECTION_DELETED",
    "MB_RTI_ASSIGNMENTS_CHANGED",
    "MB_RTSC_PLACEMENT_PREPARED",
    "MB_MODULE_REGISTERED",
    "MB_MODULE_UNREGISTERED",
    "MB_REGISTRY_CHANGED",
    "MB_ACTION_CREATED",
    "MB_ACTION_STATUS_CHANGED",
    "MB_ACTION_CONFIRMED",
    "MB_ACTION_FAILED",
    "MB_ACTION_AMBIGUOUS",
    "MB_ACTION_CANCELLED",
    "MB_ACTION_UNVERIFIED",
    "MB_ACTION_VERIFICATION_UPDATED",
    "MB_ACTION_FEEDBACK",
    "MB_PROTOCOL_EXTENSION_OBSERVED",
}

function MB:Subscribe(moduleName, eventName, callback)
    moduleName = self:Trim(moduleName)
    eventName = self:Trim(eventName)
    if moduleName == "" or eventName == "" or type(callback) ~= "function" then return nil, "INVALID_SUBSCRIPTION" end
    self.subscriptionSequence = self.subscriptionSequence + 1
    local token = "sub-" .. tostring(self.subscriptionSequence)
    self.subscriptions[eventName] = self.subscriptions[eventName] or {}
    local entry = { token = token, moduleName = moduleName, eventName = eventName, callback = callback }
    self.subscriptions[eventName][token] = entry
    self.subscriptionByToken[token] = entry
    return token
end

function MB:Unsubscribe(token)
    local entry = self.subscriptionByToken[token]
    if not entry then return false end
    local bucket = self.subscriptions[entry.eventName]
    if bucket then bucket[token] = nil end
    self.subscriptionByToken[token] = nil
    return true
end

function MB:UnsubscribeModule(moduleName)
    local remove = {}
    for token, entry in pairs(self.subscriptionByToken) do
        if entry.moduleName == moduleName then remove[#remove + 1] = token end
    end
    for _, token in ipairs(remove) do self:Unsubscribe(token) end
end

function MB:Emit(eventName, ...)
    local bucket = self.subscriptions[eventName]
    if not bucket then return end
    local callbacks = {}
    for _, entry in pairs(bucket) do callbacks[#callbacks + 1] = entry end
    for _, entry in ipairs(callbacks) do
        if self.subscriptionByToken[entry.token] then
            self:SafeCall(entry.callback, eventName, ...)
        end
    end
end
