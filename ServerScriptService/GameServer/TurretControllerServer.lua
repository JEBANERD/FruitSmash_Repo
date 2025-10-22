local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local FruitConfig = require(ReplicatedStorage.Shared.Config.FruitConfig)
local FruitSpawnerServer = require(ServerScriptService.GameServer:WaitForChild("FruitSpawnerServer"))

local TurretControllerServer = {}

local DEFAULT_WAVE_DURATION = 20 -- seconds of coverage for the shot cadence calculations

local function getLaneCount(level)
    local laneSettings = GameConfig.Lanes
    local lanes = laneSettings.StartCount

    if laneSettings.UnlockAt then
        for _, unlockLevel in ipairs(laneSettings.UnlockAt) do
            if level >= unlockLevel then
                lanes += 1
            end
        end
    end

    if laneSettings.MaxCount then
        lanes = math.min(lanes, laneSettings.MaxCount)
    end

    return lanes
end

local function computeShotsPerSecond(level)
    local turretSettings = GameConfig.Turrets
    local base = turretSettings.BaseShotsPerSecond or 0
    local pct = turretSettings.ShotsPerLevelPct or 0

    if level <= 1 then
        return base
    end

    local scaling = 1 + (level - 1) * pct
    return base * scaling
end

local function buildFruitBag(rng)
    local roster = FruitConfig.All and FruitConfig.All() or FruitConfig.Roster
    local bag = {}

    for fruitId in pairs(roster) do
        table.insert(bag, fruitId)
    end

    table.sort(bag)

    local nextIndex = 1

    local function shuffle()
        for i = #bag, 2, -1 do
            local j = rng:NextInteger(1, i)
            bag[i], bag[j] = bag[j], bag[i]
        end
    end

    shuffle()

    return function()
        if #bag == 0 then
            return nil
        end

        if nextIndex > #bag then
            nextIndex = 1
            shuffle()
        end

        local fruitId = bag[nextIndex]
        nextIndex += 1
        return fruitId
    end
end

local function chooseLanes(rng, laneCount, level)
    local turretSettings = GameConfig.Turrets
    local canTwo = level >= (turretSettings.TwoAtOnceLevel or math.huge)
    local canThree = level >= (turretSettings.ThreeAtOnceLevel or math.huge)

    local maxSimultaneous = 1
    if canThree and laneCount >= 3 then
        local chance = 0.2 + math.min(0.05 * (level - turretSettings.ThreeAtOnceLevel), 0.3)
        if rng:NextNumber() < chance then
            maxSimultaneous = 3
        end
    end

    if maxSimultaneous < 3 and canTwo and laneCount >= 2 then
        local chance = 0.45
        if rng:NextNumber() < chance then
            maxSimultaneous = 2
        end
    end

    maxSimultaneous = math.min(maxSimultaneous, laneCount)

    local lanes = {}
    for lane = 1, laneCount do
        table.insert(lanes, lane)
    end

    for i = #lanes, 2, -1 do
        local j = rng:NextInteger(1, i)
        lanes[i], lanes[j] = lanes[j], lanes[i]
    end

    local selection = {}
    for i = 1, maxSimultaneous do
        selection[i] = lanes[i]
    end

    return selection
end

function TurretControllerServer.SchedulePattern(arenaId, level)
    assert(arenaId ~= nil, "arenaId is required")
    assert(level ~= nil, "level is required")

    local ok, startErr = pcall(FruitSpawnerServer.Start, arenaId)
    if not ok then
        warn(string.format("[TurretControllerServer] Failed to start FruitSpawnerServer for arena '%s': %s", tostring(arenaId), tostring(startErr)))
    end

    local rng = Random.new()
    local laneCount = getLaneCount(level)
    local shotsPerSecond = computeShotsPerSecond(level)
    local laneScaling = laneCount / GameConfig.Lanes.StartCount
    local shotsPerWave = math.max(1, math.floor(shotsPerSecond * DEFAULT_WAVE_DURATION * laneScaling))
    local interval = shotsPerSecond > 0 and (1 / shotsPerSecond) or DEFAULT_WAVE_DURATION / math.max(shotsPerWave, 1)

    local nextFruit = buildFruitBag(rng)
    local scheduled = {}
    local currentTime = 0

    for _ = 1, shotsPerWave do
        local shotLanes = chooseLanes(rng, laneCount, level)
        local jitter = rng:NextNumber(-0.25, 0.35) * interval
        currentTime = math.max(0, currentTime + interval + jitter)

        table.insert(scheduled, { time = currentTime, lanes = shotLanes })

        task.delay(currentTime, function()
            for _, lane in ipairs(shotLanes) do
                local fruitId = nextFruit()
                if fruitId then
                    local success, err = pcall(FruitSpawnerServer.Queue, arenaId, lane, fruitId)
                    if not success then
                        warn(string.format("[TurretControllerServer] Failed to queue fruit '%s' for arena '%s': %s", tostring(fruitId), tostring(arenaId), tostring(err)))
                    end
                end
            end
        end)
    end

    return scheduled
end

return TurretControllerServer

