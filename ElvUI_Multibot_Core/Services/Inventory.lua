local _, MB = ...

local NATIVE_ITEM_ACTIONS = {
    BANK_DEPOSIT = true,
    BANK_WITHDRAW = true,
    GBANK_DEPOSIT = true,
    GBANK_WITHDRAW = true,
    BUY_ITEM = true,
}

local UTILITY_ITEM_ACTIONS = {
    SELL_GREY = { capability = "INVENTORY_BULK_SELL_V1", requiresTarget = true, risk = "ITEM_MUTATION" },
    SELL_VENDOR = { capability = "INVENTORY_BULK_SELL_V1", requiresTarget = true, risk = "ITEM_MUTATION" },
}

local INTENTIONALLY_UNSUPPORTED_INVENTORY_ACTIONS = {
    OPEN_ITEMS = {
        capability = "INVENTORY_OPEN_V1",
        reason = "INTENTIONALLY_UNSUPPORTED",
        note = "Removed after live testing showed low practical value and no reliable authoritative success signal distinguishable from autonomous Playerbots inventory/gear changes.",
    },
}

local function hasCurrentTarget()
    if type(UnitExists) == "function" then return not not UnitExists("target") end
    if type(UnitName) == "function" then
        local name = UnitName("target")
        return name ~= nil and name ~= "" and name ~= "Unknown Entity"
    end
    return false
end

local ITEM_ACTION_SOURCE = {
    BANK_DEPOSIT = "BOT.INVENTORY",
    GBANK_DEPOSIT = "BOT.INVENTORY",
    BANK_WITHDRAW = "BOT.BANK",
    GBANK_WITHDRAW = "BOT.GUILD_BANK",
    BUY_ITEM = "VENDOR",
}

local SEMANTIC_ITEM_ACTIONS = {
    USE = { actionId = "ITEM.USE", chatRoute = true, nativeCapability = "ITEM_USE_V1", verification = "BRIDGE_ACK_OR_INVENTORY_POSTCONDITION", risk = "NON_IDEMPOTENT" },
    EQUIP = { actionId = "ITEM.EQUIP", chatRoute = true, nativeCapability = "ITEM_EQUIP_V1", verification = "BRIDGE_ACK_OR_BEST_EFFORT_SENT", risk = "ITEM_MUTATION" },
    SELL = { actionId = "ITEM.SELL", chatRoute = true, nativeCapability = "ITEM_SELL_SINGLE_V1", verification = "BRIDGE_ACK_OR_INVENTORY_POSTCONDITION", risk = "ITEM_MUTATION", requiresMerchantContext = true },
    DESTROY = { actionId = "ITEM.DESTROY", chatRoute = true, nativeCapability = "ITEM_DESTROY_V1", verification = "BRIDGE_ACK_OR_INVENTORY_POSTCONDITION", risk = "DESTRUCTIVE", requiresConfirmation = true },
    GIVE = { actionId = "ITEM.GIVE", chatRoute = true, nativeCapability = "ITEM_TRADE_V1", verification = "BRIDGE_TRADE_SLOT_OR_BEST_EFFORT_SENT", risk = "ITEM_TRANSFER", coreOwnsTrade = true },
}

local function normalizeQuery(self, query)
    if type(query) == "number" then return { itemId = query } end
    if type(query) == "string" then
        local itemId = self:ExtractItemId(query)
        if itemId then return { itemId = itemId } end
        local text = self:Lower(self:Trim(query))
        return text ~= "" and { text = text } or {}
    end
    return type(query) == "table" and query or {}
end

local function matchesText(self, item, text)
    if not text or text == "" then return true end
    local fields = { item.name, item.serverLink, item.link, item.type, item.subType, item.equipLoc }
    for _, value in ipairs(fields) do
        if value and string.find(self:Lower(tostring(value)), text, 1, true) then return true end
    end
    return false
end

local function matchesItem(self, item, query)
    if query.itemId and tonumber(item.itemId) ~= tonumber(query.itemId) then return false end
    if query.name and self:Lower(self:Trim(item.name)) ~= self:Lower(self:Trim(query.name)) then return false end
    if query.type and self:Lower(self:Trim(item.type)) ~= self:Lower(self:Trim(query.type)) then return false end
    if query.subType and self:Lower(self:Trim(item.subType)) ~= self:Lower(self:Trim(query.subType)) then return false end
    if query.equipLoc and self:Upper(self:Trim(item.equipLoc)) ~= self:Upper(self:Trim(query.equipLoc)) then return false end
    if query.equipCandidate ~= nil and (item.equipCandidate == true) ~= (query.equipCandidate == true) then return false end
    if query.metadataResolved ~= nil and (item.metadataResolved == true) ~= (query.metadataResolved == true) then return false end
    if query.minQuality and (tonumber(item.quality) or -1) < tonumber(query.minQuality) then return false end
    if query.maxQuality and (tonumber(item.quality) or -1) > tonumber(query.maxQuality) then return false end
    if query.locationKnown ~= nil and (item.locationKnown == true) ~= (query.locationKnown == true) then return false end
    if query.text and not matchesText(self, item, self:Lower(self:Trim(query.text))) then return false end
    if type(query.predicate) == "function" then
        local ok, result = pcall(query.predicate, self:Copy(item))
        if not ok or result == false then return false end
    end
    return true
end

local function addBucket(root, key, item)
    key = tostring(key or "")
    if key == "" then key = "UNKNOWN" end
    local bucket = root[key]
    if not bucket then
        bucket = { key = key, stackCount = 0, totalQuantity = 0, itemIds = {}, items = {} }
        root[key] = bucket
    end
    bucket.stackCount = bucket.stackCount + 1
    bucket.totalQuantity = bucket.totalQuantity + math.max(1, tonumber(item.count) or 1)
    if tonumber(item.itemId) and tonumber(item.itemId) > 0 then bucket.itemIds[tonumber(item.itemId)] = true end
    bucket.items[#bucket.items + 1] = item
end

local function sortedBucketList(self, root)
    local out = {}
    for _, key in ipairs(self:SortedKeys(root)) do
        local bucket = root[key]
        local ids = {}
        for itemId in pairs(bucket.itemIds or {}) do ids[#ids + 1] = itemId end
        table.sort(ids)
        out[#out + 1] = {
            key = bucket.key,
            stackCount = bucket.stackCount,
            totalQuantity = bucket.totalQuantity,
            itemIds = ids,
            items = self:Copy(bucket.items),
        }
    end
    return out
end

local function countMap(value)
    local n = 0
    for _ in pairs(value or {}) do n = n + 1 end
    return n
end

function MB:GetInventoryLayout(botRef)
    local snapshot, meta = self:GetData("BOT.INVENTORY", botRef)
    if not snapshot then return nil, meta end
    local exact, exactMeta = self:GetData("BOT.INVENTORY_EXACT", botRef)
    local observed = self.bridge and self.bridge.observedExtensions or {}
    local exactAvailable = type(exact) == "table" and exact.hasPhysicalLocations == true
    local flatPhysical = snapshot.hasPhysicalLocations == true
    return {
        -- This describes BOT.INVENTORY only. Physical bag/slot authority lives in
        -- BOT.INVENTORY_EXACT and must not be projected onto aggregated flat rows.
        model = snapshot.locationModel or "FLAT",
        hasPhysicalLocations = flatPhysical,
        fields = self:Copy(snapshot.locationFields or { bag = false, slot = false, equipmentSlot = false }),
        exactStackAddressable = flatPhysical,
        equipmentReadback = snapshot.equipmentReadback == true,
        exactSnapshotAvailable = exactAvailable,
        exactMeta = self:Copy(exactMeta),
        observedLocationExtensions = {
            INV_BAG = observed.INV_BAG ~= nil or exactAvailable,
            INV_ITEM_LOC = observed.INV_ITEM_LOC ~= nil or exactAvailable,
            INV_EQUIP_LOC = observed.INV_EQUIP_LOC ~= nil,
        },
    }, meta
end

function MB:GetInventoryExactView(botRef)
    local snapshot, meta = self:GetData("BOT.INVENTORY_EXACT", botRef)
    if not snapshot then return nil, meta end
    local items = self:Copy(snapshot.items or {})
    table.sort(items, function(a, b)
        local ab, bb = tonumber(a.bag) or 999, tonumber(b.bag) or 999
        if ab ~= bb then return ab < bb end
        return (tonumber(a.slot) or 999) < (tonumber(b.slot) or 999)
    end)
    return {
        schemaVersion = tonumber(snapshot.schemaVersion) or 1,
        name = snapshot.name,
        bot = self:ResolveBot(botRef),
        bags = self:Copy(snapshot.bags or {}),
        items = items,
        itemsByPosition = self:Copy(snapshot.itemsByPosition or {}),
        summary = self:Copy(snapshot.summary or {}),
        layout = {
            model = snapshot.locationModel or "PHYSICAL",
            hasPhysicalLocations = snapshot.hasPhysicalLocations == true,
            exactStackAddressable = snapshot.exactStackAddressable == true,
            equipmentReadback = snapshot.equipmentReadback == true,
            fields = self:Copy(snapshot.locationFields or { bag = true, slot = true, soulbound = true, equipmentSlot = false }),
        },
    }, meta
end

function MB:GetBuybackView(botRef)
    local snapshot, meta = self:GetData("BOT.BUYBACK", botRef)
    if not snapshot then return nil, meta end
    local items = self:Copy(snapshot.items or {})
    table.sort(items, function(a, b)
        local at, bt = tonumber(a.timestamp) or 0, tonumber(b.timestamp) or 0
        if at == bt then return (tonumber(a.slot) or 0) > (tonumber(b.slot) or 0) end
        return at > bt
    end)
    return {
        schemaVersion = tonumber(snapshot.schemaVersion) or 1, name = snapshot.name, bot = self:ResolveBot(botRef),
        status = snapshot.status, reason = snapshot.reason, items = items, count = #items,
        slotModel = snapshot.slotModel or "VENDOR_BUYBACK_74_TO_85",
    }, meta
end

local function resolveBuybackEntry(self, botRef, selector)
    local view, meta = self:GetBuybackView(botRef)
    if not view then return nil, meta and (meta.error or meta.status) or "BUYBACK_DATA_REQUIRED", meta end
    local slot, itemId
    if type(selector) == "number" then
        if selector >= 74 and selector <= 85 then slot = selector else itemId = selector end
    elseif type(selector) == "table" then
        slot = selector.slot ~= nil and tonumber(selector.slot) or nil
        itemId = selector.itemId ~= nil and tonumber(selector.itemId) or nil
    elseif type(selector) == "string" then
        local n = tonumber(selector)
        if n and n >= 74 and n <= 85 then slot = n else itemId = self:ExtractItemId(selector) or n end
    end
    local matches = {}
    for _, entry in ipairs(view.items or {}) do
        if (slot == nil or tonumber(entry.slot) == slot) and (itemId == nil or tonumber(entry.itemId) == itemId) then matches[#matches + 1] = entry end
    end
    if #matches == 0 then return nil, "BUYBACK_ITEM_NOT_FOUND", meta end
    if #matches > 1 and slot == nil then return nil, "AMBIGUOUS_BUYBACK_ITEM", meta, matches end
    return self:Copy(matches[1]), nil, meta
end

function MB:GetBuybackAvailability(botRef, selector)
    if not self.bridge or not self.bridge.connected then return { enabled = false, reason = "BRIDGE_NOT_CONNECTED" } end
    if not self.bridge.handshakeReady or self.bridge.capabilitiesResolved ~= true then return { enabled = false, reason = "BRIDGE_NOT_READY" } end
    if not self:BridgeHasCapability("INVENTORY_EXACT_V1") or not self:BridgeHasCapability("VENDOR_BUYBACK_V1") then return { enabled = false, reason = "CAPABILITY_UNAVAILABLE" } end
    local entry, err, meta, matches = resolveBuybackEntry(self, botRef, selector)
    if not entry then return { enabled = false, reason = err or "BUYBACK_ITEM_NOT_FOUND", sourceMeta = self:Copy(meta), matches = self:Copy(matches) } end
    local availability = self:GetActionAvailability("ITEM.BUYBACK", botRef, { slot = entry.slot, itemId = entry.itemId, count = entry.count, price = entry.price })
    availability.buybackEntry = entry
    availability.requiredDomain = "BOT.BUYBACK"
    availability.route = "BRIDGE_NATIVE"
    return availability
end

function MB:ExecuteBuyback(originModule, botRef, selector, callback)
    local availability = self:GetBuybackAvailability(botRef, selector)
    if not availability or availability.enabled ~= true then return nil, availability and availability.reason or "BUYBACK_UNAVAILABLE", availability end
    local e = availability.buybackEntry or {}
    return self:ExecuteAction(originModule, "ITEM.BUYBACK", botRef, { slot = e.slot, itemId = e.itemId, count = e.count, price = e.price }, callback)
end

function MB:ResolveExactInventoryStack(botRef, itemId, sourceBag, sourceSlot)
    itemId = tonumber(itemId) or 0
    if itemId <= 0 then return nil, "ITEM_ID_REQUIRED" end
    local view, meta = self:GetInventoryExactView(botRef)
    if not view then return nil, meta and (meta.error or meta.status) or "EXACT_INVENTORY_REQUIRED", meta end
    sourceBag = sourceBag ~= nil and tonumber(sourceBag) or nil
    sourceSlot = sourceSlot ~= nil and tonumber(sourceSlot) or nil
    local matches = {}
    for _, item in ipairs(view.items or {}) do
        if tonumber(item.itemId) == itemId
            and (sourceBag == nil or tonumber(item.bag) == sourceBag)
            and (sourceSlot == nil or tonumber(item.slot) == sourceSlot) then
            matches[#matches + 1] = item
        end
    end
    if #matches == 0 then return nil, "ITEM_NOT_FOUND_EXACT", meta end
    table.sort(matches, function(a, b)
        if (tonumber(a.bag) or 999) ~= (tonumber(b.bag) or 999) then return (tonumber(a.bag) or 999) < (tonumber(b.bag) or 999) end
        return (tonumber(a.slot) or 999) < (tonumber(b.slot) or 999)
    end)
    return self:Copy(matches[1]), nil, meta
end

local function exactPositionKey(bag, slot)
    return tostring(tonumber(bag) or -1) .. ":" .. tostring(tonumber(slot) or -1)
end

function MB:IsExactInventoryPositionValid(botRef, bag, slot)
    local view, meta = self:GetInventoryExactView(botRef)
    if not view then return false, meta and (meta.error or meta.status) or "EXACT_INVENTORY_REQUIRED" end
    bag, slot = tonumber(bag), tonumber(slot)
    if bag == nil or slot == nil then return false, "POSITION_REQUIRED" end
    for _, descriptor in ipairs(view.bags or {}) do
        if tonumber(descriptor.bag) == bag then
            local first = tonumber(descriptor.slotStart) or 0
            local count = tonumber(descriptor.slotCount) or 0
            if slot >= first and slot < first + count then return true, nil, self:Copy(descriptor) end
        end
    end
    return false, "INVALID_DESTINATION_POSITION"
end

function MB:GetInventoryMoveAvailability(botRef, sourceBag, sourceSlot, destinationBag, destinationSlot)
    if not self.bridge or not self.bridge.connected then return { enabled = false, reason = "BRIDGE_NOT_CONNECTED" } end
    if not self.bridge.handshakeReady or self.bridge.capabilitiesResolved ~= true then return { enabled = false, reason = "BRIDGE_NOT_READY" } end
    if not self:BridgeHasCapability("INVENTORY_EXACT_V1") or not self:BridgeHasCapability("ITEM_MOVE_V1") then
        return { enabled = false, reason = "CAPABILITY_UNAVAILABLE" }
    end
    sourceBag, sourceSlot, destinationBag, destinationSlot = tonumber(sourceBag), tonumber(sourceSlot), tonumber(destinationBag), tonumber(destinationSlot)
    if sourceBag == nil or sourceSlot == nil or destinationBag == nil or destinationSlot == nil then return { enabled = false, reason = "POSITION_REQUIRED" } end
    if sourceBag == destinationBag and sourceSlot == destinationSlot then return { enabled = false, reason = "SAME_POSITION" } end
    local view, meta = self:GetInventoryExactView(botRef)
    if not view then return { enabled = false, reason = "EXACT_INVENTORY_REQUIRED", sourceMeta = self:Copy(meta) } end
    local source = view.itemsByPosition and view.itemsByPosition[exactPositionKey(sourceBag, sourceSlot)] or nil
    if not source then return { enabled = false, reason = "SOURCE_ITEM_NOT_FOUND" } end
    local valid, reason, bagDescriptor = self:IsExactInventoryPositionValid(botRef, destinationBag, destinationSlot)
    if not valid then return { enabled = false, reason = reason or "INVALID_DESTINATION_POSITION" } end
    local destination = view.itemsByPosition and view.itemsByPosition[exactPositionKey(destinationBag, destinationSlot)] or nil
    local availability = self:GetActionAvailability("ITEM.MOVE", botRef, {
        srcBag = sourceBag, srcSlot = sourceSlot, srcItemId = source.itemId, srcCount = source.count,
        dstBag = destinationBag, dstSlot = destinationSlot, dstItemId = destination and destination.itemId or 0, dstCount = destination and destination.count or 0,
    })
    availability.source = self:Copy(source)
    availability.destination = self:Copy(destination)
    availability.destinationBag = self:Copy(bagDescriptor)
    availability.requiredDomain = "BOT.INVENTORY_EXACT"
    return availability
end

function MB:ExecuteInventoryMove(originModule, botRef, sourceBag, sourceSlot, destinationBag, destinationSlot, callback)
    local availability = self:GetInventoryMoveAvailability(botRef, sourceBag, sourceSlot, destinationBag, destinationSlot)
    if not availability or availability.enabled ~= true then return nil, availability and availability.reason or "ITEM_MOVE_UNAVAILABLE", availability end
    local source, destination = availability.source or {}, availability.destination
    return self:ExecuteAction(originModule, "ITEM.MOVE", botRef, {
        srcBag = tonumber(sourceBag), srcSlot = tonumber(sourceSlot), srcItemId = tonumber(source.itemId), srcCount = tonumber(source.count),
        dstBag = tonumber(destinationBag), dstSlot = tonumber(destinationSlot), dstItemId = destination and tonumber(destination.itemId) or 0, dstCount = destination and tonumber(destination.count) or 0,
    }, callback)
end

function MB:GetInventoryUnequipAvailability(botRef, equipmentSlot, itemId)
    equipmentSlot, itemId = tonumber(equipmentSlot), tonumber(itemId)
    if equipmentSlot == nil or equipmentSlot < 0 or equipmentSlot > 18 or math.floor(equipmentSlot) ~= equipmentSlot then
        return { enabled = false, reason = "INVALID_EQUIPMENT_SLOT" }
    end
    if itemId == nil or itemId <= 0 or math.floor(itemId) ~= itemId then return { enabled = false, reason = "ITEM_ID_REQUIRED" } end
    local availability = self:GetActionAvailability("ITEM.UNEQUIP", botRef, { equipmentSlot = equipmentSlot, itemId = itemId })
    availability.equipmentSlot = equipmentSlot
    availability.itemId = itemId
    availability.slotModel = "SERVER_0_BASED_0_TO_18"
    return availability
end

function MB:ExecuteInventoryUnequip(originModule, botRef, equipmentSlot, itemId, callback)
    local availability = self:GetInventoryUnequipAvailability(botRef, equipmentSlot, itemId)
    if not availability or availability.enabled ~= true then return nil, availability and availability.reason or "ITEM_UNEQUIP_UNAVAILABLE", availability end
    return self:ExecuteAction(originModule, "ITEM.UNEQUIP", botRef, { equipmentSlot = tonumber(equipmentSlot), itemId = tonumber(itemId) }, callback)
end

function MB:GetInventoryView(botRef)
    local snapshot, meta = self:GetData("BOT.INVENTORY", botRef)
    if not snapshot then return nil, meta end

    local items = {}
    local totalQuantity, metadataResolved, serverLinks, equipmentCandidates, located = 0, 0, 0, 0, 0
    for index, raw in ipairs(snapshot.items or {}) do
        local item = self:EnrichInventoryItem(raw)
        item.index = tonumber(item.index) or index
        item.snapshotIndex = index
        item.recordKey = tostring(tonumber(item.itemId) or 0) .. ":" .. tostring(index)
        item.recordKeyStable = false
        totalQuantity = totalQuantity + math.max(1, tonumber(item.count) or 1)
        if item.metadataResolved then metadataResolved = metadataResolved + 1 end
        if item.serverLink then serverLinks = serverLinks + 1 end
        if item.equipCandidate then equipmentCandidates = equipmentCandidates + 1 end
        if item.locationKnown then located = located + 1 end
        items[#items + 1] = item
    end

    local byItemId = self:AggregateItems(items)
    local summary = self:Copy(snapshot.summary or {})
    summary.gold = tonumber(summary.gold) or 0
    summary.silver = tonumber(summary.silver) or 0
    summary.copper = tonumber(summary.copper) or 0
    summary.bagUsed = tonumber(summary.bagUsed) or 0
    summary.bagTotal = tonumber(summary.bagTotal) or 0
    summary.bagFree = math.max(0, summary.bagTotal - summary.bagUsed)
    summary.moneyCopper = summary.gold * 10000 + summary.silver * 100 + summary.copper
    summary.stackCount = #items
    summary.totalQuantity = totalQuantity
    summary.uniqueItemCount = countMap(byItemId)
    summary.metadataResolvedCount = metadataResolved
    summary.metadataUnresolvedCount = math.max(0, #items - metadataResolved)
    summary.serverLinkCount = serverLinks
    summary.equipmentCandidateCount = equipmentCandidates
    summary.locationKnownCount = located

    local exactSnapshot = self:GetData("BOT.INVENTORY_EXACT", botRef)
    local exactAvailable = type(exactSnapshot) == "table" and exactSnapshot.hasPhysicalLocations == true
    local flatPhysical = snapshot.hasPhysicalLocations == true
    local layout = {
        -- Keep the compatibility/metadata view truthful: these rows are aggregated
        -- and therefore do not inherit bag/slot identity from BOT.INVENTORY_EXACT.
        model = snapshot.locationModel or "FLAT",
        hasPhysicalLocations = flatPhysical,
        fields = self:Copy(snapshot.locationFields or { bag = false, slot = false, equipmentSlot = false }),
        exactStackAddressable = flatPhysical,
        equipmentReadback = snapshot.equipmentReadback == true,
        exactSnapshotAvailable = exactAvailable,
    }

    local view = {
        schemaVersion = tonumber(snapshot.schemaVersion) or 2,
        name = snapshot.name,
        bot = self:ResolveBot(botRef),
        summary = summary,
        items = items,
        byItemId = byItemId,
        stackCount = #items,
        totalQuantity = totalQuantity,
        uniqueItemCount = summary.uniqueItemCount,
        layout = layout,
        addressing = {
            bridgeItemAction = layout.exactStackAddressable and "BAG_SLOT_ITEM_COUNT" or "ITEM_ID_COUNT",
            exactStack = layout.exactStackAddressable,
            snapshotRecordKeysStable = false,
            preservesServerHyperlink = serverLinks > 0,
        },
    }
    if view.bot then view.bot = self:Copy(view.bot) end
    return view, meta
end

local STORAGE_DOMAIN = {
    BANK = "BOT.BANK",
    GBANK = "BOT.GUILD_BANK",
    GUILD_BANK = "BOT.GUILD_BANK",
}

function MB:GetStorageView(botRef, kind)
    kind = self:Upper(kind)
    local domain = STORAGE_DOMAIN[kind]
    if not domain then return nil, { status = "ERROR", error = "UNSUPPORTED_STORAGE_KIND" } end
    local snapshot, meta = self:GetData(domain, botRef)
    if not snapshot then return nil, meta end
    local items, totalQuantity = {}, 0
    for index, raw in ipairs(snapshot.items or {}) do
        local item = self:EnrichInventoryItem(raw)
        item.index = tonumber(item.index) or index
        item.snapshotIndex = index
        item.recordKey = tostring(tonumber(item.itemId) or 0) .. ":" .. tostring(index)
        item.recordKeyStable = false
        totalQuantity = totalQuantity + math.max(1, tonumber(item.count) or 1)
        items[#items + 1] = item
    end
    local byItemId = self:AggregateItems(items)
    return {
        schemaVersion = 1,
        name = snapshot.name,
        kind = kind == "GUILD_BANK" and "GBANK" or kind,
        domain = domain,
        items = items,
        byItemId = byItemId,
        stackCount = #items,
        totalQuantity = totalQuantity,
        uniqueItemCount = countMap(byItemId),
        rights = self:Copy(snapshot.rights),
        error = snapshot.error,
        layout = {
            model = snapshot.locationModel or "FLAT",
            hasPhysicalLocations = snapshot.hasPhysicalLocations == true,
            exactStackAddressable = snapshot.hasPhysicalLocations == true,
        },
        addressing = { bridgeItemAction = "ITEM_ID_COUNT", exactStack = snapshot.hasPhysicalLocations == true },
    }, meta
end

function MB:GetBankView(botRef)
    return self:GetStorageView(botRef, "BANK")
end

function MB:GetGuildBankView(botRef)
    return self:GetStorageView(botRef, "GBANK")
end

function MB:GetInventorySummary(botRef)
    local view, meta = self:GetInventoryView(botRef)
    if not view then return nil, meta end
    return self:Copy(view.summary), meta
end

function MB:FindInventoryItems(botRef, query)
    local view, meta = self:GetInventoryView(botRef)
    if not view then return nil, meta end
    query = normalizeQuery(self, query)
    local out = {}
    for _, item in ipairs(view.items or {}) do
        if matchesItem(self, item, query) then out[#out + 1] = self:Copy(item) end
    end
    return out, meta
end

function MB:GetInventoryItemCount(botRef, itemId)
    itemId = self:ExtractItemId(itemId)
    if not itemId then return nil, "ITEM_ID_REQUIRED" end
    local view, meta = self:GetInventoryView(botRef)
    if not view then return nil, meta end
    local aggregate = view.byItemId and view.byItemId[itemId]
    return aggregate and (tonumber(aggregate.count) or 0) or 0, meta
end

local function resolveItemFromSnapshot(self, snapshot, selector)
    if type(snapshot) ~= "table" then return nil, "SOURCE_DATA_REQUIRED" end
    local items = {}
    for _, raw in ipairs(snapshot.items or {}) do items[#items + 1] = self:EnrichInventoryItem(raw) end
    local byItemId = self:AggregateItems(items)

    local requestedLink
    if type(selector) == "string" then requestedLink = self:ExtractItemLink(selector)
    elseif type(selector) == "table" then requestedLink = selector.serverLink or self:ExtractItemLink(selector.link or selector.rawLine) end

    local itemId = self:ExtractItemId(selector)
    if not itemId and type(selector) == "string" then
        local wanted = self:Lower(self:Trim(selector))
        if wanted ~= "" then
            local ids = {}
            for _, item in ipairs(items) do
                if self:Lower(self:Trim(item.name)) == wanted then ids[tonumber(item.itemId) or 0] = true end
            end
            ids[0] = nil
            local found
            for id in pairs(ids) do
                if found and found ~= id then return nil, "AMBIGUOUS_ITEM_NAME" end
                found = id
            end
            itemId = found
        end
    end
    if not itemId then return nil, "ITEM_SELECTOR_REQUIRED" end
    local aggregate = byItemId[itemId]
    if not aggregate then return nil, "ITEM_NOT_FOUND" end

    local allRecords = self:Copy(aggregate.records or {})
    local variantMap, variants = {}, {}
    for _, record in ipairs(allRecords) do
        local link = record.serverLink or record.link
        if link and link ~= "" and not variantMap[link] then
            variantMap[link] = true
            variants[#variants + 1] = link
        end
    end
    table.sort(variants)

    local records = allRecords
    if requestedLink then
        records = {}
        for _, record in ipairs(allRecords) do
            if record.serverLink == requestedLink or record.link == requestedLink then records[#records + 1] = record end
        end
        if #records == 0 then return nil, "ITEM_VARIANT_NOT_FOUND" end
    end

    local selectedCount = 0
    for _, record in ipairs(records) do selectedCount = selectedCount + math.max(1, tonumber(record.count) or 1) end
    local representative = records[1] and self:Copy(records[1]) or nil
    return {
        itemId = itemId,
        name = representative and representative.name or nil,
        serverLink = requestedLink or (representative and representative.serverLink or nil),
        clientLink = representative and representative.clientLink or nil,
        transportLink = (representative and representative.clientLink) or requestedLink or (representative and representative.serverLink) or (representative and representative.link) or nil,
        transportLinkSource = (representative and representative.clientLink) and "CLIENT_GETITEMINFO" or "BRIDGE_SERVER_FALLBACK",
        link = requestedLink or (representative and representative.link or nil),
        totalCount = requestedLink and selectedCount or (tonumber(aggregate.count) or 0),
        aggregateTotalCount = tonumber(aggregate.count) or 0,
        stackCount = #records,
        aggregateStackCount = #allRecords,
        records = self:Copy(records),
        representative = representative,
        variants = self:Copy(variants),
        variantCount = #variants,
        exactVariantSelected = requestedLink ~= nil,
        bridgeAddress = { itemId = itemId, addressKind = "ITEM_ID_COUNT" },
        exactStackAddressable = snapshot.hasPhysicalLocations == true,
    }
end

function MB:ResolveInventoryItem(botRef, selector)
    local snapshot, meta = self:GetData("BOT.INVENTORY", botRef)
    if not snapshot then return nil, meta and (meta.error or meta.status) or "INVENTORY_UNAVAILABLE", meta end
    local item, err = resolveItemFromSnapshot(self, snapshot, selector)
    return item, err, meta
end

function MB:GetInventoryEquipmentCandidates(botRef, query)
    local base = normalizeQuery(self, query)
    base.equipCandidate = true
    return self:FindInventoryItems(botRef, base)
end

function MB:GetInventoryIndex(botRef)
    local view, meta = self:GetInventoryView(botRef)
    if not view then return nil, meta end
    local byType, bySubType, byEquipLoc, byQuality = {}, {}, {}, {}
    for _, item in ipairs(view.items or {}) do
        addBucket(byType, item.type, item)
        addBucket(bySubType, item.subType, item)
        addBucket(byEquipLoc, item.equipLoc, item)
        addBucket(byQuality, tonumber(item.quality) or -1, item)
    end
    return {
        byItemId = self:Copy(view.byItemId),
        byType = sortedBucketList(self, byType),
        bySubType = sortedBucketList(self, bySubType),
        byEquipLoc = sortedBucketList(self, byEquipLoc),
        byQuality = sortedBucketList(self, byQuality),
        uniqueItemCount = view.uniqueItemCount,
    }, meta
end

local function nativeSemanticRouteAvailable(self, action)
    local descriptor = SEMANTIC_ITEM_ACTIONS[self:Upper(action)]
    return descriptor ~= nil
        and self.bridge ~= nil
        and self.bridge.connected == true
        and self.bridge.handshakeReady == true
        and self:BridgeHasCapability("INVENTORY_EXACT_V1")
        and self:BridgeHasCapability(descriptor.nativeCapability)
end

local function exactDepositRouteAvailable(self, action, count)
    action = self:Upper(action)
    return (action == "BANK_DEPOSIT" or action == "GBANK_DEPOSIT")
        and (tonumber(count) or 0) == 0
        and self.bridge ~= nil
        and self.bridge.connected == true
        and self.bridge.handshakeReady == true
        and self.bridge.capabilitiesResolved == true
        and self:BridgeHasCapability("INVENTORY_EXACT_V1")
        and self:BridgeHasCapability("ITEM_DEPOSIT_EXACT_V1")
end

function MB:GetInventoryCapabilities(botRef)
    local layout, meta = self:GetInventoryLayout(botRef)
    local snapshotAvailable = layout ~= nil
    local exactSnapshot = self:GetData("BOT.INVENTORY_EXACT", botRef)
    local exactSnapshotAvailable = type(exactSnapshot) == "table" and exactSnapshot.hasPhysicalLocations == true
    if not layout then
        layout = {
            model = "FLAT", hasPhysicalLocations = false,
            fields = { bag = false, slot = false, equipmentSlot = false },
            exactStackAddressable = false, equipmentReadback = false,
            exactSnapshotAvailable = exactSnapshotAvailable,
        }
    end
    local native = {}
    for action in pairs(NATIVE_ITEM_ACTIONS) do
        local exactDeposit = (action == "BANK_DEPOSIT" or action == "GBANK_DEPOSIT")
            and self:BridgeHasCapability("INVENTORY_EXACT_V1")
            and self:BridgeHasCapability("ITEM_DEPOSIT_EXACT_V1")
        native[action] = {
            implemented = self.actions["ITEM.ACTION"] ~= nil,
            route = "BRIDGE", addressKind = exactDeposit and "BAG_SLOT_ITEM_COUNT" or "ITEM_ID_COUNT",
            requiredSource = ITEM_ACTION_SOURCE[action],
            requiresPossession = action == "BANK_DEPOSIT" or action == "GBANK_DEPOSIT",
            exactDepositAvailable = exactDeposit and true or false,
            selectedNativeCapability = exactDeposit and "ITEM_DEPOSIT_EXACT_V1" or nil,
        }
    end
    local semantic = {}
    for action, descriptor in pairs(SEMANTIC_ITEM_ACTIONS) do
        local nativeAvailable = nativeSemanticRouteAvailable(self, action)
        semantic[action] = {
            implemented = self.actions[descriptor.actionId] ~= nil,
            actionId = descriptor.actionId,
            route = nativeAvailable and "BRIDGE" or "CHAT",
            selectedNativeCapability = descriptor.nativeCapability,
            nativeAvailable = nativeAvailable,
            chatFallbackAvailable = self.db and self.db.chat and self.db.chat.enabled == true and type(SendChatMessage) == "function",
            addressKind = nativeAvailable and "BAG_SLOT_ITEM_COUNT" or "ITEM_LINK",
            exactStackAddressing = nativeAvailable and true or false,
            verification = descriptor.verification,
            risk = descriptor.risk,
            requiresConfirmation = descriptor.requiresConfirmation == true,
            requiresMerchantContext = descriptor.requiresMerchantContext == true,
            coreOwnsTrade = descriptor.coreOwnsTrade == true,
        }
    end
    return {
        schemaVersion = 2,
        read = true,
        snapshotAvailable = snapshotAvailable,
        exactSnapshotAvailable = exactSnapshotAvailable,
        layout = self:Copy(layout),
        itemIdentity = "ITEM_ID",
        bridgeActionAddress = exactSnapshotAvailable and "BAG_SLOT_ITEM_COUNT" or "ITEM_ID_COUNT",
        exactStackAddressing = exactSnapshotAvailable,
        preservesServerHyperlink = true,
        equipment = {
            bridgeReadback = layout.equipmentReadback == true,
            readback = layout.equipmentReadback == true,
            candidateClassification = true,
            authoritativeEquippedState = layout.equipmentReadback == true,
            clientObserved = self.IsEquipmentObservationSupported and self:IsEquipmentObservationSupported() or false,
            clientObservation = self.GetEquipmentObservationCapabilities and self:GetEquipmentObservationCapabilities(botRef) or nil,
        },
        nativeActions = native,
        semanticActions = semantic,
        exactOperations = {
            move = { implemented = self.actions["ITEM.MOVE"] ~= nil, available = self:BridgeHasCapability("INVENTORY_EXACT_V1") and self:BridgeHasCapability("ITEM_MOVE_V1"), capability = "ITEM_MOVE_V1", addressKind = "SOURCE_AND_DESTINATION_BAG_SLOT_GUARDS" },
            unequip = { implemented = self.actions["ITEM.UNEQUIP"] ~= nil, available = self:BridgeHasCapability("ITEM_UNEQUIP_V1"), capability = "ITEM_UNEQUIP_V1", slotModel = "SERVER_0_BASED_0_TO_18" },
            exactDeposit = { implemented = self.actions["ITEM.ACTION"] ~= nil, available = self:BridgeHasCapability("INVENTORY_EXACT_V1") and self:BridgeHasCapability("ITEM_DEPOSIT_EXACT_V1"), capability = "ITEM_DEPOSIT_EXACT_V1", fullStackOnly = true },
        },
        utilityActions = {
            openItems = { action = "OPEN_ITEMS", implemented = false, available = false, capability = "INVENTORY_OPEN_V1", reason = "INTENTIONALLY_UNSUPPORTED", advertisedByBridge = self:BridgeHasCapability("INVENTORY_OPEN_V1") },
            sellGrey = { action = "SELL_GREY", implemented = self.actions["ITEM.ACTION"] ~= nil, available = self:BridgeHasCapability("INVENTORY_V1") and self:BridgeHasCapability("INVENTORY_BULK_SELL_V1"), capability = "INVENTORY_BULK_SELL_V1", requiresTarget = true },
            sellVendor = { action = "SELL_VENDOR", implemented = self.actions["ITEM.ACTION"] ~= nil, available = self:BridgeHasCapability("INVENTORY_V1") and self:BridgeHasCapability("INVENTORY_BULK_SELL_V1"), capability = "INVENTORY_BULK_SELL_V1", requiresTarget = true },
            buyback = { actionId = "ITEM.BUYBACK", implemented = self.actions["ITEM.BUYBACK"] ~= nil, available = self:BridgeHasCapability("INVENTORY_EXACT_V1") and self:BridgeHasCapability("VENDOR_BUYBACK_V1"), capability = "VENDOR_BUYBACK_V1", requiresExactInventory = true, requiredDomain = "BOT.BUYBACK" },
        },
    }, meta
end

function MB:GetInventoryInteractionContract(action)
    action = self:Upper(action)
    local removed = INTENTIONALLY_UNSUPPORTED_INVENTORY_ACTIONS[action]
    if removed then
        return {
            action = action, actionId = nil, route = "NONE", addressKind = "NONE", requiredSource = nil,
            verification = "NONE", risk = "NONE", nativeCapability = removed.capability,
            implemented = false, available = false, reason = removed.reason, fallbackRoute = nil,
            note = removed.note,
        }
    end
    local utility = UTILITY_ITEM_ACTIONS[action]
    if utility then
        return {
            action = action, actionId = "ITEM.ACTION", route = "BRIDGE", addressKind = "NONE", requiredSource = "BOT.INVENTORY",
            verification = "BRIDGE_ACK", risk = utility.risk, nativeCapability = utility.capability,
            requiresTarget = utility.requiresTarget == true, fallbackRoute = nil,
            note = "Structured bridge utility action. No item selector is accepted and no chat fallback is used after dispatch.",
        }
    end
    if NATIVE_ITEM_ACTIONS[action] then
        local exactDeposit = exactDepositRouteAvailable(self, action, 0)
        return {
            action = action, actionId = "ITEM.ACTION", route = "BRIDGE",
            addressKind = exactDeposit and "BAG_SLOT_ITEM_COUNT" or "ITEM_ID_COUNT", requiredSource = ITEM_ACTION_SOURCE[action],
            exactStackAddressing = exactDeposit, verification = "BRIDGE_ACK",
            risk = action == "BUY_ITEM" and "NON_IDEMPOTENT" or "ITEM_MUTATION",
            nativeCapability = exactDeposit and "ITEM_DEPOSIT_EXACT_V1" or nil,
            fallbackRoute = exactDeposit and "BRIDGE_GENERIC" or nil,
            note = exactDeposit
                and "BANK/GBANK deposit prefers ITEM_DEPOSIT_EXACT_V1 for a full physical stack and falls back to the existing bridge ITEM_ACTION route before dispatch when exact deposit is unavailable or a partial count is requested."
                or "Legacy bridge-native ITEM_ACTION endpoint using itemId+count.",
        }
    end
    local descriptor = SEMANTIC_ITEM_ACTIONS[action]
    if not descriptor then return nil, "UNSUPPORTED_INVENTORY_ACTION" end
    local nativeAvailable = nativeSemanticRouteAvailable(self, action)
    return {
        action = action,
        actionId = descriptor.actionId,
        route = nativeAvailable and "BRIDGE" or "CHAT",
        nativeCapability = descriptor.nativeCapability,
        nativeAvailable = nativeAvailable,
        addressKind = nativeAvailable and "BAG_SLOT_ITEM_COUNT" or "ITEM_LINK",
        exactStackAddressing = nativeAvailable,
        requiresServerLink = not nativeAvailable,
        requiresConfirmation = descriptor.requiresConfirmation == true,
        requiresMerchantContext = descriptor.requiresMerchantContext == true,
        coreOwnsTrade = descriptor.coreOwnsTrade == true,
        verification = descriptor.verification,
        risk = descriptor.risk,
        fallbackRoute = "CHAT",
        note = nativeAvailable
            and "Core resolves a fresh INVENTORY_EXACT_V1 physical source, sends the dedicated structured item mutation, validates the correlated response, then refreshes canonical inventory."
            or (action == "GIVE"
                and "Compatibility route: Core opens trade, waits for TRADE_SHOW, then whispers give <item hyperlink>; Core never accepts the trade."
                or "Compatibility route: Core sends the validated Playerbots item hyperlink command and verifies through shared inventory when possible."),
    }
end

local function normalizeInventoryActionOptions(value)
    if type(value) == "number" then return { count = value } end
    if type(value) ~= "table" then return {} end
    return value
end

function MB:GetInventoryActionAvailability(botRef, action, selector, options)
    action = self:Upper(action)
    options = normalizeInventoryActionOptions(options)
    local removed = INTENTIONALLY_UNSUPPORTED_INVENTORY_ACTIONS[action]
    if removed then
        return {
            enabled = false, reason = removed.reason, action = action,
            capability = removed.capability, advertisedByBridge = self:BridgeHasCapability(removed.capability),
            interaction = self:GetInventoryInteractionContract(action), note = removed.note,
        }
    end
    local count = tonumber(options.count) or 0
    if count < 0 then return { enabled = false, reason = "INVALID_COUNT", action = action } end

    local utility = UTILITY_ITEM_ACTIONS[action]
    if utility then
        if not self.bridge or not self.bridge.connected then return { enabled = false, reason = "BRIDGE_NOT_CONNECTED", action = action } end
        if not self.bridge.handshakeReady or self.bridge.capabilitiesResolved ~= true then return { enabled = false, reason = "BRIDGE_NOT_READY", action = action } end
        if not self:BridgeHasCapability("INVENTORY_V1") or not self:BridgeHasCapability(utility.capability) then return { enabled = false, reason = "CAPABILITY_UNAVAILABLE", action = action } end
        if utility.requiresTarget and not hasCurrentTarget() then return { enabled = false, reason = "TARGET_REQUIRED", action = action } end
        local availability = self:GetActionAvailability("ITEM.ACTION", botRef, { action = action, itemId = 0, count = 0, selectedRoute = "BRIDGE_GENERIC" })
        availability.inventoryAction = action
        availability.requiredDomain = "BOT.INVENTORY"
        availability.interaction = self:GetInventoryInteractionContract(action)
        availability.selectedRoute = "BRIDGE_GENERIC"
        return availability
    end

    if NATIVE_ITEM_ACTIONS[action] then
        local sourceDomain
        if action == "BANK_DEPOSIT" or action == "GBANK_DEPOSIT" then sourceDomain = "BOT.INVENTORY"
        elseif action == "BANK_WITHDRAW" then sourceDomain = "BOT.BANK"
        elseif action == "GBANK_WITHDRAW" then sourceDomain = "BOT.GUILD_BANK" end

        local item, err, sourceMeta
        if action == "BUY_ITEM" then
            local itemId = self:ExtractItemId(selector)
            if not itemId then return { enabled = false, reason = "ITEM_ID_REQUIRED", action = action, requiredSource = "VENDOR" } end
            item = { itemId = itemId, bridgeAddress = { itemId = itemId, addressKind = "ITEM_ID_COUNT" }, exactStackAddressable = false }
        else
            local snapshot
            snapshot, sourceMeta = self:GetData(sourceDomain, botRef)
            if not snapshot then return { enabled = false, reason = "SOURCE_DATA_REQUIRED", action = action, requiredDomain = sourceDomain, sourceMeta = self:Copy(sourceMeta) } end
            item, err = resolveItemFromSnapshot(self, snapshot, selector)
            if not item then return { enabled = false, reason = err or "ITEM_NOT_FOUND", action = action, requiredDomain = sourceDomain } end
            if action == "GBANK_WITHDRAW" and snapshot.rights and snapshot.rights.canWithdraw == false then
                return { enabled = false, reason = "GUILD_BANK_WITHDRAW_DENIED", action = action, item = item, requiredDomain = sourceDomain }
            end
            if count > 0 and count > (tonumber(item.totalCount) or 0) then
                return { enabled = false, reason = "INSUFFICIENT_ITEM_COUNT", action = action, item = item, requestedCount = count, requiredDomain = sourceDomain }
            end
        end
        local selectedRoute = exactDepositRouteAvailable(self, action, count) and "BRIDGE_EXACT" or "BRIDGE_GENERIC"
        local availability = self:GetActionAvailability("ITEM.ACTION", botRef, {
            action = action, itemId = item.itemId, count = count, selectedRoute = selectedRoute,
            sourceBag = options.sourceBag, sourceSlot = options.sourceSlot,
        })
        availability.inventoryItem = item
        availability.inventoryAction = action
        availability.requiredDomain = selectedRoute == "BRIDGE_EXACT" and "BOT.INVENTORY_EXACT" or sourceDomain
        availability.interaction = self:GetInventoryInteractionContract(action)
        availability.selectedRoute = selectedRoute
        return availability
    end

    local semantic = SEMANTIC_ITEM_ACTIONS[action]
    if not semantic then return { enabled = false, reason = "UNSUPPORTED_INVENTORY_ACTION", action = action } end
    if self.bridge and self.bridge.connected == true and self.bridge.handshakeReady == true and self.bridge.capabilitiesResolved ~= true then
        return { enabled = false, reason = "BRIDGE_CAPABILITIES_PENDING", action = action }
    end
    local item, err, meta = self:ResolveInventoryItem(botRef, selector)
    if not item then return { enabled = false, reason = err or "ITEM_NOT_FOUND", action = action, requiredDomain = "BOT.INVENTORY", sourceMeta = self:Copy(meta) } end

    local nativeAvailable = nativeSemanticRouteAvailable(self, action)
    local sourceBag = options.sourceBag ~= nil and tonumber(options.sourceBag) or nil
    local sourceSlot = options.sourceSlot ~= nil and tonumber(options.sourceSlot) or nil
    if (tonumber(item.variantCount) or 0) > 1 and (not nativeAvailable or sourceBag == nil or sourceSlot == nil) then
        return { enabled = false, reason = "AMBIGUOUS_ITEM_VARIANT", action = action, inventoryItem = item, requiredDomain = "BOT.INVENTORY", variants = self:Copy(item.variants or {}) }
    end

    local clientLink = item.clientLink or (item.representative and item.representative.clientLink)
    local serverLink = item.serverLink or (item.representative and item.representative.serverLink)
    local transportLink = clientLink or serverLink or item.link
    local args = {
        itemId = item.itemId,
        itemLink = transportLink,
        itemLinkSource = clientLink and "CLIENT_GETITEMINFO" or "BRIDGE_SERVER_FALLBACK",
        clientLink = clientLink,
        serverLink = serverLink,
        confirmed = options.confirmed == true,
        selectedRoute = nativeAvailable and "BRIDGE_NATIVE" or "CHAT",
        sourceBag = sourceBag,
        sourceSlot = sourceSlot,
    }
    if not nativeAvailable and (not transportLink or transportLink == "") then
        return { enabled = false, reason = "ITEM_LINK_REQUIRED", action = action, inventoryItem = item, requiredDomain = "BOT.INVENTORY" }
    end
    local availability = self:GetActionAvailability(semantic.actionId, botRef, args)
    availability.inventoryItem = item
    availability.inventoryAction = action
    availability.requiredDomain = nativeAvailable and "BOT.INVENTORY_EXACT" or "BOT.INVENTORY"
    availability.interaction = self:GetInventoryInteractionContract(action)
    return availability
end

function MB:ExecuteInventoryAction(originModule, botRef, action, selector, options, callback)
    action = self:Upper(action)
    options = normalizeInventoryActionOptions(options)
    local availability = self:GetInventoryActionAvailability(botRef, action, selector, options)
    if not availability or availability.enabled ~= true then
        return nil, availability and availability.reason or "INVENTORY_ACTION_UNAVAILABLE", availability
    end

    if UTILITY_ITEM_ACTIONS[action] then
        return self:ExecuteAction(originModule, "ITEM.ACTION", botRef, { action = action, itemId = 0, count = 0, selectedRoute = "BRIDGE_GENERIC" }, callback)
    end

    if NATIVE_ITEM_ACTIONS[action] then
        local item = availability.inventoryItem or {}
        local normalized = availability.normalizedArgs or {}
        return self:ExecuteAction(originModule, "ITEM.ACTION", botRef, {
            action = action, itemId = item.itemId, count = tonumber(options.count) or 0,
            selectedRoute = normalized.selectedRoute or availability.selectedRoute or "BRIDGE_GENERIC",
            sourceBag = options.sourceBag, sourceSlot = options.sourceSlot,
        }, callback)
    end

    local descriptor = SEMANTIC_ITEM_ACTIONS[action]
    local item = availability.inventoryItem or {}
    local normalized = availability.normalizedArgs or {}
    local verificationBaseline = self.CaptureItemVerificationBaseline and self:CaptureItemVerificationBaseline(botRef, action, item) or nil
    return self:ExecuteAction(originModule, descriptor.actionId, botRef, {
        itemId = item.itemId,
        itemLink = normalized.itemLink,
        itemLinkSource = normalized.itemLinkSource,
        clientLink = normalized.clientLink,
        serverLink = normalized.serverLink,
        confirmed = options.confirmed == true,
        selectedRoute = normalized.selectedRoute,
        sourceBag = normalized.sourceBag,
        sourceSlot = normalized.sourceSlot,
        verificationBaseline = verificationBaseline,
    }, callback)
end

