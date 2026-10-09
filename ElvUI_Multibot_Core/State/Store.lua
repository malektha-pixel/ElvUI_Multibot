local _, MB = ...

function MB:CacheKey(domainId, targetKey)
    return tostring(domainId) .. "\031" .. tostring(targetKey or "GLOBAL")
end

function MB:NormalizeDomainTarget(domainId, target, allowUnknown)
    local descriptor = self.dataDomains[domainId]
    if not descriptor then return nil, nil, "UNKNOWN_DOMAIN" end
    if descriptor.scope == "GLOBAL" then return "GLOBAL", { targetKey = "GLOBAL" } end

    local botRef, variant
    if descriptor.scope == "BOT_VARIANT" then
        if type(target) ~= "table" then return nil, nil, "BOT_VARIANT_TARGET_REQUIRED" end
        botRef = target.bot or target.name or target.botName or target.target or target.key or target.botKey
        variant = target[descriptor.variantField or "variant"] or target.variant
        if tonumber(variant) then variant = tonumber(variant) end
        if variant == nil or variant == "" or tonumber(variant) == 0 then return nil, nil, "VARIANT_REQUIRED" end
    else
        botRef = type(target) == "table" and (target.bot or target.name or target.botName or target.key or target.botKey) or target
    end

    local bot = self.ResolveBot and self:ResolveBot(botRef) or nil
    local botName = bot and bot.name or self:NormalizeName(botRef)
    local botKey = bot and bot.key or self:BotKey(botName)
    if not botKey then return nil, nil, "BOT_REQUIRED" end
    if not bot and allowUnknown ~= true and self.initialized and next(self.botRegistry) ~= nil then
        -- Reads may still be requested for a bridge-known bot not yet in the local registry; do not reject hard.
    end

    if descriptor.scope == "BOT_VARIANT" then
        local targetKey = botKey .. "|" .. tostring(variant)
        return targetKey, { targetKey = targetKey, botKey = botKey, botName = botName or botKey, variant = variant, [descriptor.variantField or "variant"] = variant }
    end
    return botKey, { targetKey = botKey, botKey = botKey, botName = botName or botKey }
end

function MB:CommitData(domainId, targetKey, value, metadata)
    local key = self:CacheKey(domainId, targetKey)
    local old = self.cache[key]
    local changed = not old or not self:DeepEqual(old.value, value)
    local revision = old and ((old.meta and old.meta.revision or 0) + 1) or 1
    local meta = self:Merge({}, old and old.meta or {})
    meta = self:Merge(meta, metadata or {})
    meta.domain = domainId
    meta.targetKey = targetKey
    meta.updatedAt = self:Now()
    meta.revision = revision
    meta.stale = false
    meta.error = nil
    local entry = { value = value, meta = meta }
    self.cache[key] = entry
    self.runtime.counters.cacheCommits = self.runtime.counters.cacheCommits + 1
    if changed then self.runtime.counters.cacheChanges = self.runtime.counters.cacheChanges + 1 end
    self:Emit("MB_DATA_UPDATED", domainId, targetKey, self:Copy(value), self:Copy(meta))
    if changed then self:Emit("MB_DATA_CHANGED", domainId, targetKey, self:Copy(value), self:Copy(meta)) end
    -- Historical retention is passive and separate from the canonical live cache.
    -- It never satisfies API:Get(), preflight, verification, or mutation paths.
    if self.RetainLastKnown then self:RetainLastKnown(domainId, targetKey, value, meta) end
    if self.OnDataCommitted then self:OnDataCommitted(domainId, targetKey, meta) end
    return entry
end

function MB:GetData(domainId, target)
    local targetKey, _, err = self:NormalizeDomainTarget(domainId, target, true)
    if not targetKey then return nil, { status = "ERROR", error = err } end
    local entry = self.cache[self:CacheKey(domainId, targetKey)]
    if not entry then return nil, { status = "MISSING", stale = true, targetKey = targetKey } end
    if domainId == "BOT.EQUIPMENT" and self.ValidateEquipmentSnapshotAccess then
        local allowed, guardedMeta = self:ValidateEquipmentSnapshotAccess(target, entry)
        if not allowed then return nil, guardedMeta end
        return self:Copy(entry.value), guardedMeta
    elseif domainId == "BOT.TALENTS" and self.ValidateTalentSnapshotAccess then
        local allowed, guardedMeta = self:ValidateTalentSnapshotAccess(target, entry)
        if not allowed then return nil, guardedMeta end
        return self:Copy(entry.value), guardedMeta
    end
    return self:Copy(entry.value), self:Copy(entry.meta)
end

function MB:GetDataByKey(domainId, targetKey)
    local entry = self.cache[self:CacheKey(domainId, targetKey)]
    if not entry then return nil, nil end
    return self:Copy(entry.value), self:Copy(entry.meta)
end

function MB:GetDataMeta(domainId, target)
    local targetKey = self:NormalizeDomainTarget(domainId, target, true)
    if not targetKey then return nil end
    local entry = self.cache[self:CacheKey(domainId, targetKey)]
    if entry and domainId == "BOT.EQUIPMENT" and self.ValidateEquipmentSnapshotAccess then
        local _, guardedMeta = self:ValidateEquipmentSnapshotAccess(target, entry)
        return guardedMeta
    elseif entry and domainId == "BOT.TALENTS" and self.ValidateTalentSnapshotAccess then
        local _, guardedMeta = self:ValidateTalentSnapshotAccess(target, entry)
        return guardedMeta
    end
    return entry and self:Copy(entry.meta) or nil
end

function MB:InvalidateData(domainId, targetKey, reason)
    local key = self:CacheKey(domainId, targetKey)
    local entry = self.cache[key]
    if entry then
        entry.meta = entry.meta or {}
        entry.meta.stale = true
        entry.meta.invalidatedAt = self:Now()
        entry.meta.invalidatedReason = reason
    end
    self:Emit("MB_DATA_INVALIDATED", domainId, targetKey, reason)
    if self.QueueInterestedRefresh then self:QueueInterestedRefresh(domainId, targetKey) end
end

function MB:SetDataError(domainId, targetKey, errorCode)
    local key = self:CacheKey(domainId, targetKey)
    local entry = self.cache[key]
    if entry then
        entry.meta = entry.meta or {}
        entry.meta.error = errorCode
        entry.meta.lastErrorAt = self:Now()
    end
    self:Emit("MB_DATA_ERROR", domainId, targetKey, errorCode)
end

function MB:ClearCache()
    self.cache = {}
    self:Emit("MB_REGISTRY_CHANGED", "CACHE", "CLEARED")
end
