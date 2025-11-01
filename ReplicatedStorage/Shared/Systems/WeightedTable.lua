--!strict

type WeightedEntry = {
    Weight: number?,
    [string]: any,
}

type WeightedTableModule = {
    Pick: (entries: { WeightedEntry }, rng: Random?) -> WeightedEntry?,
}

local WeightedTable = {} :: WeightedTableModule

local function resolveNextNumber(rng: Random?, minimum: number, maximum: number): number
    if rng then
        local rngType = typeof(rng)

        if rngType == "Random" then
            return rng:NextNumber(minimum, maximum)
        end

        local nextNumber = (rng :: any).NextNumber
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

function WeightedTable.Pick(entries: { WeightedEntry }, rng: Random?): WeightedEntry?
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

return WeightedTable
