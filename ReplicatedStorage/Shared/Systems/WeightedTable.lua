local WeightedTable = {}

local function resolveNextNumber(rng, minimum, maximum)
    if rng then
        local rngType = typeof and typeof(rng) or type(rng)

        if rngType == "Random" then
            return rng:NextNumber(minimum, maximum)
        end

        local nextNumber = rng.NextNumber
        if type(nextNumber) == "function" then
            local success, value = pcall(nextNumber, minimum, maximum)
            if success then
                return value
            end

            success, value = pcall(function()
                return nextNumber(rng, minimum, maximum)
            end)

            if success then
                return value
            end
        end
    end

    return Random.new():NextNumber(minimum, maximum)
end

function WeightedTable.Pick(entries, rng)
    if type(entries) ~= "table" or #entries == 0 then
        return nil
    end

    local totalWeight = 0
    for _, entry in ipairs(entries) do
        local weight = entry.Weight or 0
        if weight > 0 then
            totalWeight += weight
        end
    end

    if totalWeight <= 0 then
        return nil
    end

    local threshold = resolveNextNumber(rng, 0, totalWeight)
    local cumulative = 0

    for _, entry in ipairs(entries) do
        local weight = entry.Weight or 0
        if weight > 0 then
            cumulative += weight
            if threshold <= cumulative then
                return entry
            end
        end
    end

    return nil
end

--[=[
    Unit Test Stub:
    describe("WeightedTable", function()
        it("returns nil when weights sum to zero", function()
            -- local result = WeightedTable.Pick({ { ItemId = 1, Weight = 0 } })
            -- expect(result).to.equal(nil)
        end)

        it("selects entries proportionally", function()
            -- local mockRng = { NextNumber = function(_, minimum, maximum)
            --     return minimum + (maximum - minimum) * 0.6
            -- end }
            -- local result = WeightedTable.Pick({
            --     { ItemId = "A", Weight = 4 },
            --     { ItemId = "B", Weight = 6 },
            -- }, mockRng)
            -- expect(result.ItemId).to.equal("B")
        end)
    end)
]=]

return WeightedTable
