local _, MB = ...

local function normalizeOptions(value)
    if type(value) == "table" then return value end
    if value == nil then return {} end
    return { slot = value }
end

function MB:GetTalentSpecApplyAvailability(botRef, specIndex, options)
    options = normalizeOptions(options)
    local availability = self:GetActionAvailability("TALENT.SPEC_APPLY", botRef, {
        specIndex = specIndex,
        slot = options.slot,
    })
    availability = availability or { enabled = false, reason = "TALENT_SPEC_APPLY_UNAVAILABLE" }
    availability.actionId = "TALENT.SPEC_APPLY"
    availability.specIndex = tonumber(specIndex)
    availability.requestedSlot = options.slot == nil and "CURRENT" or options.slot
    availability.requiredDomain = "BOT.TALENT_SPECS"
    if availability.normalizedArgs then
        availability.selectedSpec = availability.normalizedArgs.specName and {
            index = availability.normalizedArgs.specIndex,
            name = availability.normalizedArgs.specName,
            build = availability.normalizedArgs.specBuild,
        } or nil
    end

    -- This synchronous helper is intended for UI enable/disable state. Require a
    -- fresh list so the frontend never presents an arbitrary/stale premade index
    -- as immediately executable. ApplyTalentSpec itself still performs another
    -- fresh read immediately before dispatch as the mutation safety boundary.
    if availability.enabled == true and availability.requiresFreshTalentSpecs == true then
        availability.enabled = false
        availability.reason = "TALENT_SPECS_REQUIRED"
        availability.requiresRefresh = true
    end
    return availability
end

function MB:ApplyTalentSpec(originModule, botRef, specIndex, options, callback)
    options = normalizeOptions(options)
    return self:ExecuteAction(originModule, "TALENT.SPEC_APPLY", botRef, {
        specIndex = specIndex,
        slot = options.slot,
    }, callback)
end
