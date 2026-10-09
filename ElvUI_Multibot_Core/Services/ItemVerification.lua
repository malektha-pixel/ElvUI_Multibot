local _, MB = ...

MB.itemVerificationByBot = MB.itemVerificationByBot or {}

local VERIFY_ACTIONS = {
    USE = true,
    SELL = true,
    DESTROY = true,
}

local function emitVerification(self, tx)
    self:Emit("MB_ACTION_VERIFICATION_UPDATED", tx.id, self:Copy(tx.verification), self:TransactionSnapshot(tx))
end

local function unwatch(self, tx)
    local bot = tx and tx.targets and tx.targets[1]
    if not bot then return end
    local bucket = self.itemVerificationByBot[bot.key]
    if bucket then
        bucket[tx.id] = nil
        if next(bucket) == nil then self.itemVerificationByBot[bot.key] = nil end
    end
end

local function countItemInSnapshot(snapshot, itemId)
    if type(snapshot) ~= "table" then return nil end
    local aggregate = snapshot.byItemId and snapshot.byItemId[tonumber(itemId)]
    if aggregate then return tonumber(aggregate.count) or tonumber(aggregate.totalCount) or 0 end
    local total = 0
    for _, item in ipairs(snapshot.items or {}) do
        if tonumber(item.itemId) == tonumber(itemId) then total = total + math.max(1, tonumber(item.count) or 1) end
    end
    return total
end

function MB:CaptureItemVerificationBaseline(botRef, action, item)
    action = self:Upper(action)
    if not VERIFY_ACTIONS[action] then return nil end
    local bot = self:ResolveBot(botRef)
    if not bot or not item or not item.itemId then return nil end

    local inventory, inventoryMeta = self:GetData("BOT.INVENTORY", bot.name)
    local baseline = {
        action = action,
        botKey = bot.key,
        botName = bot.name,
        itemId = tonumber(item.itemId),
        itemName = item.name,
        beforeInventoryCount = countItemInSnapshot(inventory, item.itemId),
        beforeInventoryRevision = inventoryMeta and inventoryMeta.revision or nil,
        capturedAt = self:Now(),
    }

    return baseline
end

function MB:BeginItemPostVerification(tx)
    if type(tx) ~= "table" or tx.state ~= "SENT_UNVERIFIED" then return false end
    local action = self:Upper(tx.itemAction)
    if not VERIFY_ACTIONS[action] then return false end
    local baseline = tx.args and tx.args.verificationBaseline
    local bot = tx.targets and tx.targets[1]
    if type(baseline) ~= "table" or not bot then return false end

    tx.verification = {
        status = "PENDING",
        policy = "BRIDGE_INVENTORY_COUNT_POSTCONDITION",
        action = action,
        itemId = tonumber(tx.itemId) or tonumber(baseline.itemId),
        beforeInventoryCount = baseline.beforeInventoryCount,
        attempts = 0,
        startedAt = self:Now(),
    }
    self.itemVerificationByBot[bot.key] = self.itemVerificationByBot[bot.key] or {}
    self.itemVerificationByBot[bot.key][tx.id] = true
    emitVerification(self, tx)

    local txId, epoch = tx.id, tx.sessionEpoch
    self:After(0.45, function() MB:RunItemPostVerification(txId, epoch, 1) end)
    return true
end

function MB:CompleteItemVerification(tx, status, proof, after)
    if not tx or not tx.verification then return end
    tx.verification.status = status
    tx.verification.proof = proof
    tx.verification.afterInventoryCount = after and after.inventoryCount or tx.verification.afterInventoryCount
    tx.verification.completedAt = self:Now()
    unwatch(self, tx)
    emitVerification(self, tx)
    if status == "CONFIRMED" and tx.state == "SENT_UNVERIFIED" then
        self:SetTransactionState(tx, "CONFIRMED", { verifiedAt = self:Now() })
    end
end

function MB:EvaluateItemPostVerification(tx, inventory)
    local verification = tx.verification or {}
    local action = self:Upper(verification.action)
    local itemId = verification.itemId
    local afterInventory = countItemInSnapshot(inventory, itemId)
    verification.afterInventoryCount = afterInventory

    local beforeInventory = tonumber(verification.beforeInventoryCount)
    if beforeInventory ~= nil and afterInventory ~= nil and afterInventory < beforeInventory then
        local proof = action == "USE" and "BRIDGE_INVENTORY_CONSUMED"
            or action == "SELL" and "BRIDGE_INVENTORY_REMOVED"
            or action == "DESTROY" and "BRIDGE_INVENTORY_REMOVED"
            or "BRIDGE_INVENTORY_CHANGED"
        return true, proof, { inventoryCount = afterInventory }
    end
    return false, nil, { inventoryCount = afterInventory }
end

function MB:RunItemPostVerification(txId, epoch, attempt)
    local tx = self.transactions and self.transactions[txId] or nil
    if not tx or tx.sessionEpoch ~= epoch or tx.state ~= "SENT_UNVERIFIED" or not tx.verification then return end
    local bot = tx.targets and tx.targets[1]
    if not bot then return end
    tx.verification.attempts = math.max(tonumber(tx.verification.attempts) or 0, tonumber(attempt) or 1)
    emitVerification(self, tx)

    self:RefreshDomain("BOT.INVENTORY", bot.name, function(inventory, inventoryMeta)
        local current = MB.transactions and MB.transactions[txId] or nil
        if not current or current.sessionEpoch ~= epoch or current.state ~= "SENT_UNVERIFIED" then return end

        local function evaluate()
            local confirmed, proof, after = MB:EvaluateItemPostVerification(current, inventory)
            current.verification.inventoryRevision = inventoryMeta and inventoryMeta.revision or nil
            current.verification.inventoryError = inventoryMeta and inventoryMeta.error or nil
            if confirmed then
                MB:CompleteItemVerification(current, "CONFIRMED", proof, after)
                return
            end
            current.verification.afterInventoryCount = after and after.inventoryCount or nil
            emitVerification(MB, current)
            if attempt < 3 then
                local delays = { [1] = 0.70, [2] = 1.10 }
                MB:After(delays[attempt] or 0.80, function() MB:RunItemPostVerification(txId, epoch, attempt + 1) end)
            else
                MB:CompleteItemVerification(current, "UNVERIFIED", "POSTCONDITION_NOT_OBSERVED", after)
            end
        end

        evaluate()
    end)
end
