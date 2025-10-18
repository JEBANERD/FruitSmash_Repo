local RNG = require(script.Parent.RNG)

local WeightedTable = {}

--[[
    Unit Test Stub:
    describe("WeightedTable.Pick", function()
        it("returns nil when every weight is zero", function()
            -- stub for automated test harness
        end)
    end)
]]

local function resolveRoll(rng, min, max)
    if rng == nil then
        return RNG.NextNumber(min, max)
    end

    local success, value = pcall(function()
        return rng:NextNumber(min, max)
    end)

    if success then
        return value
    end

    local nextNumber = rng.NextNumber
    if type(nextNumber) == "function" then
        success, value = pcall(function()
            return nextNumber(min, max)
        end)

        if success then
            return value
        end

        success, value = pcall(function()
            return nextNumber(rng, min, max)
        end)

        if success then
            return value
        end
    end

    error("WeightedTable.Pick received an invalid RNG")
end

function WeightedTable.Pick(entries, rng)
    if type(entries) ~= "table" then
        error("WeightedTable.Pick requires a table of entries")
    end

    local totalWeight = 0

    for _, entry in ipairs(entries) do
        local weight = entry.Weight or entry.weight or 0

        if type(weight) == "number" and weight > 0 then
            totalWeight = totalWeight + weight
        end
    end

    if totalWeight <= 0 then
        return nil
    end

    local roll = resolveRoll(rng, 0, totalWeight)

    local cumulative = 0

    for _, entry in ipairs(entries) do
        local weight = entry.Weight or entry.weight or 0

        if type(weight) == "number" and weight > 0 then
            cumulative = cumulative + weight

            if roll <= cumulative then
                return entry
            end
        end
    end

    return entries[#entries]
end

return WeightedTable
