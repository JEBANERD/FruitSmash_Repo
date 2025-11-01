--!strict

type RNGModule = {
    NextNumber: (minimum: number?, maximum: number?) -> number,
    NextInteger: (minimum: number, maximum: number) -> number,
    Chance: (probability: number?) -> boolean,
}

local RNG = {} :: RNGModule

local seededRandom: Random?

local function getRandom(): Random
    if not seededRandom then
        seededRandom = Random.new(os.clock())
    end

    return seededRandom
end

function RNG.NextNumber(minimum: number?, maximum: number?): number
    local random = getRandom()
    if minimum ~= nil and maximum ~= nil then
        return random:NextNumber(minimum, maximum)
    elseif minimum ~= nil then
        return random:NextNumber(minimum, 1)
    elseif maximum ~= nil then
        return random:NextNumber(0, maximum)
    end

    return random:NextNumber()
end

function RNG.NextInteger(minimum: number, maximum: number): number
    return getRandom():NextInteger(minimum, maximum)
end

function RNG.Chance(probability: number?): boolean
    local chance = probability or 0

    if chance <= 0 then
        return false
    elseif chance >= 1 then
        return true
    end

    return getRandom():NextNumber() < chance
end

return RNG
