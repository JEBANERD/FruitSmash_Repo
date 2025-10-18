local RNG = {}

--[[
    Unit Test Stub:
    describe("RNG.NextNumber", function()
        it("returns deterministic values when seeded", function()
            -- stub for automated test harness
        end)
    end)
]]

local seededRandom

local function getRandom()
    if not seededRandom then
        seededRandom = Random.new(os.clock())
    end

    return seededRandom
end

function RNG.NextNumber(min, max)
    min = min or 0
    max = max or 1

    return getRandom():NextNumber(min, max)
end

function RNG.NextInteger(min, max)
    min = min or 0
    max = max or 1

    return getRandom():NextInteger(min, max)
end

function RNG.Chance(probability)
    probability = math.clamp(probability or 0, 0, 1)

    return RNG.NextNumber() <= probability
end

return RNG
