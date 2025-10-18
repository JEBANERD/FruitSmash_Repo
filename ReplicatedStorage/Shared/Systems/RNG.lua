local RNG = {}

local seededRandom

local function getRandom()
    if not seededRandom then
        seededRandom = Random.new(os.clock())
    end

    return seededRandom
end

function RNG.NextNumber(minimum, maximum)
    return getRandom():NextNumber(minimum, maximum)
end

function RNG.NextInteger(minimum, maximum)
    return getRandom():NextInteger(minimum, maximum)
end

function RNG.Chance(probability)
    probability = probability or 0

    if probability <= 0 then
        return false
    elseif probability >= 1 then
        return true
    end

    return getRandom():NextNumber() < probability
end

--[=[
    Unit Test Stub:
    describe("RNG", function()
        it("returns deterministic results when seeded", function()
            -- local first = RNG.NextNumber()
            -- expect(first).to.equal(RNG.NextNumber())
        end)

        it("supports probability checks", function()
            -- expect(RNG.Chance(0)).to.equal(false)
            -- expect(RNG.Chance(1)).to.equal(true)
        end)
    end)
]=]

return RNG
