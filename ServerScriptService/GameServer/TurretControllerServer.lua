local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("GameConfig"))
local FruitConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("FruitConfig"))
local FruitSpawnerServer = require(ServerScriptService:WaitForChild("GameServer"):WaitForChild("FruitSpawnerServer"))
local ArenaAdapter = require(ServerScriptService:WaitForChild("GameServer"):WaitForChild("ArenaAdapter"))

local TurretControllerServer = {}

local TurretSettings = GameConfig.Turrets or {}
local LaneConfig = GameConfig.Lanes or {}
local MatchConfig = GameConfig.Match or {}

local DEBUG_ENABLED = MatchConfig.DebugPrint == true
local DEFAULT_LEVEL = 1
local DEFAULT_IDLE_WAIT = 1

local arenaStates = {}

local function computeShotsPerSecond(level)
    local base = TurretSettings.BaseShotsPerSecond or 0
    local pct = TurretSettings.ShotsPerLevelPct or 0
    local effectiveLevel = math.max(level - 1, 0)

    return base * (1 + pct * effectiveLevel)
end

local function buildFruitBag(rng)
    local roster = FruitConfig.All and FruitConfig.All() or FruitConfig.Roster
    local bag = {}

    if type(roster) == "function" then
        roster = roster()
    end

    for fruitId, entry in pairs(roster) do
        local id = entry and entry.Id or fruitId
        table.insert(bag, id)
    end

    table.sort(bag)

    local function shuffle()
        for index = #bag, 2, -1 do
            local swapIndex = rng:NextInteger(1, index)
            bag[index], bag[swapIndex] = bag[swapIndex], bag[index]
        end
    end

    local nextIndex = 1
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

local function applyContext(state, context)
    if context == nil then
        return
    end

    if typeof(context) == "number" then
        state.levelOverride = context
        return
    end

    if typeof(context) ~= "table" then
        return
    end

    if typeof(context.levelOverride) == "number" then
        state.levelOverride = context.levelOverride
    elseif typeof(context.LevelOverride) == "number" then
        state.levelOverride = context.LevelOverride
    end

    if typeof(context.level) == "number" then
        state.levelHint = context.level
    elseif typeof(context.Level) == "number" then
        state.levelHint = context.Level
    end

    if typeof(context.laneCount) == "number" then
        state.laneOverride = context.laneCount
    elseif typeof(context.lanes) == "number" then
        state.laneOverride = context.lanes
    elseif typeof(context.lanes) == "table" then
        state.laneOverride = #context.lanes
    end
end

local function getLevel(state)
    if typeof(state.levelOverride) == "number" then
        return state.levelOverride
    end

    local level

    if type(ArenaAdapter) == "table" and type(ArenaAdapter.GetLevel) == "function" then
        local ok, result = pcall(ArenaAdapter.GetLevel, state.arenaId)
        if ok and typeof(result) == "number" then
            level = result
        end
    end

    if typeof(level) ~= "number" then
        level = state.levelHint
    end

    if typeof(level) ~= "number" then
        level = DEFAULT_LEVEL
    end

    state.level = level
    return level
end

local function getLaneCount(state)
    local laneCount

    if type(ArenaAdapter) == "table" and type(ArenaAdapter.GetLaneCount) == "function" then
        local ok, result = pcall(ArenaAdapter.GetLaneCount, state.arenaId)
        if ok and typeof(result) == "number" then
            laneCount = result
        end
    end

    if typeof(state.laneOverride) == "number" then
        laneCount = math.max(laneCount or 0, state.laneOverride)
    end

    if typeof(laneCount) ~= "number" then
        laneCount = LaneConfig.StartCount or 0
    end

    return math.max(0, math.floor(laneCount))
end

local function updateLaneStats(state, laneCount)
    state.laneStats = state.laneStats or {}

    local minShots = math.huge
    for laneId, info in pairs(state.laneStats) do
        if laneId > laneCount then
            state.laneStats[laneId] = nil
        else
            if info.fired < minShots then
                minShots = info.fired
            end
        end
    end

    if minShots == math.huge then
        minShots = 0
    end

    for laneId = 1, laneCount do
        if not state.laneStats[laneId] then
            state.laneStats[laneId] = {
                id = laneId,
                fired = minShots,
                lastFired = -math.huge,
                bias = state.rng:NextNumber(),
            }
        end
    end
end

local function selectLanes(state, laneCount, desiredCount)
    if laneCount <= 0 or desiredCount <= 0 then
        return {}
    end

    desiredCount = math.clamp(desiredCount, 1, laneCount)

    updateLaneStats(state, laneCount)

    local stats = {}
    for laneId = 1, laneCount do
        local entry = state.laneStats[laneId]
        if entry then
            table.insert(stats, entry)
        end
    end

    table.sort(stats, function(a, b)
        if a.fired ~= b.fired then
            return a.fired < b.fired
        end
        if a.lastFired ~= b.lastFired then
            return a.lastFired < b.lastFired
        end
        return a.bias < b.bias
    end)

    local now = os.clock()
    local selection = {}

    for index = 1, desiredCount do
        local laneInfo = stats[index]
        if not laneInfo then
            break
        end

        table.insert(selection, laneInfo.id)
        laneInfo.fired += 1
        laneInfo.lastFired = now
    end

    return selection
end

local function computeBurstCount(level, laneCount, rng)
    if laneCount <= 0 then
        return 0
    end

    local twoLevel = TurretSettings.TwoAtOnceLevel or math.huge
    local threeLevel = TurretSettings.ThreeAtOnceLevel or math.huge

    if laneCount >= 3 and level >= threeLevel then
        local baseChance = 0.15
        local perLevel = 0.02
        local maxChance = 0.45
        local chance = math.clamp(baseChance + math.max(level - threeLevel, 0) * perLevel, baseChance, maxChance)
        if rng:NextNumber() < chance then
            return 3
        end
    end

    if laneCount >= 2 and level >= twoLevel then
        local baseChance = 0.55
        local perLevel = 0.02
        local maxChance = 0.9
        local chance = math.clamp(baseChance + math.max(level - twoLevel, 0) * perLevel, baseChance, maxChance)
        if rng:NextNumber() < chance then
            return 2
        end
    end

    return 1
end

local function queueLane(arenaId, laneId, fruitId)
    if not fruitId then
        return
    end

    if type(FruitSpawnerServer.Queue) == "function" then
        local ok, err = pcall(FruitSpawnerServer.Queue, arenaId, laneId, { FruitId = fruitId })
        if ok then
            return
        end

        warn(string.format("[TurretControllerServer] Queue failed for arena '%s' lane '%s': %s", tostring(arenaId), tostring(laneId), err))
    end

    if type(FruitSpawnerServer.SpawnFruit) == "function" then
        local ok, err = pcall(FruitSpawnerServer.SpawnFruit, arenaId, laneId, fruitId)
        if not ok then
            warn(string.format("[TurretControllerServer] Spawn fallback failed for arena '%s' lane '%s': %s", tostring(arenaId), tostring(laneId), err))
        end
    end
end

local function queueLanes(state, level, lanes)
    if #lanes == 0 then
        return
    end

    for _, laneId in ipairs(lanes) do
        queueLane(state.arenaId, laneId, state.nextFruit and state.nextFruit())
    end

    if DEBUG_ENABLED then
        print(string.format("[TurretController] Queued lanes %s @ level %d (arena %s)", table.concat(lanes, ","), level, tostring(state.arenaId)))
    end
end

local function runArena(state)
    state.lastShotTime = os.clock()

    while state.running do
        local level = getLevel(state)
        local laneCount = getLaneCount(state)

        if laneCount <= 0 then
            state.lastShotTime = os.clock()
            task.wait(DEFAULT_IDLE_WAIT)
            continue
        end

        local shotsPerSecond = computeShotsPerSecond(level)
        if shotsPerSecond <= 0 then
            state.lastShotTime = os.clock()
            task.wait(DEFAULT_IDLE_WAIT)
            continue
        end

        local interval = 1 / shotsPerSecond
        local elapsed = os.clock() - state.lastShotTime
        if elapsed < interval then
            task.wait(interval - elapsed)
        end

        if not state.running then
            break
        end

        state.lastShotTime = os.clock()

        level = getLevel(state)
        laneCount = getLaneCount(state)
        if laneCount <= 0 then
            continue
        end

        local burstCount = computeBurstCount(level, laneCount, state.rng)
        burstCount = math.clamp(burstCount, 1, laneCount)
        local lanes = selectLanes(state, laneCount, burstCount)

        if #lanes > 0 then
            queueLanes(state, level, lanes)
        end
    end
end

local function startArena(arenaId, context)
    assert(arenaId ~= nil, "arenaId is required")

    local state = arenaStates[arenaId]
    if state then
        applyContext(state, context)
        if not state.running then
            state.running = true
            state.lastShotTime = os.clock()
            state.thread = task.spawn(runArena, state)
        end
        return true
    end

    state = {
        arenaId = arenaId,
        running = true,
        rng = Random.new(),
    }

    state.nextFruit = buildFruitBag(state.rng)
    applyContext(state, context)

    arenaStates[arenaId] = state
    state.thread = task.spawn(runArena, state)

    return true
end

local function stopArena(arenaId)
    local state = arenaStates[arenaId]
    if not state then
        return
    end

    state.running = false
    arenaStates[arenaId] = nil
end

TurretControllerServer.Start = startArena
TurretControllerServer.Stop = stopArena

function TurretControllerServer:Start(arenaId, context)
    return startArena(arenaId, context)
end

function TurretControllerServer:Stop(arenaId)
    return stopArena(arenaId)
end

function TurretControllerServer.SchedulePattern(arenaId, level)
    return startArena(arenaId, level)
end

function TurretControllerServer:SchedulePattern(arenaId, level)
    return startArena(arenaId, level)
end

function TurretControllerServer.SchedulePatterns(_, arenaId, context)
    return startArena(arenaId, context)
end

function TurretControllerServer:SchedulePatterns(arenaId, context)
    return startArena(arenaId, context)
end

return TurretControllerServer
