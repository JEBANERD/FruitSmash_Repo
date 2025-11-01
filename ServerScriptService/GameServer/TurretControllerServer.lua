--!strict
--[=[
    @module TurretControllerServer
    Coordinates automated turret firing patterns by selecting lanes, applying
    fruit spawn weights, and respecting arena-level multipliers. The module
    exposes a lightweight API so other services can schedule or tune waves.
]=]

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

local DEFAULT_RATE_MULTIPLIER = 1
local MIN_RATE_MULTIPLIER = 0
local MAX_RATE_MULTIPLIER = 20

local arenaStates = {}
local pendingRateMultipliers = {}

--[=[
    Normalizes any arena identifier into a stable string key used internally.
    @param arenaId any -- Identifier supplied by external systems.
    @return string? -- String representation or nil when arenaId is invalid.
]=]
local function resolveArenaKey(arenaId)
    if arenaId == nil then
        return nil
    end
    if typeof(arenaId) == "string" then
        return arenaId
    end
    return tostring(arenaId)
end

--[=[
    Computes the turret firing rate for a given level using configuration data.
    @param level number -- Arena or match level used for scaling.
    @return number -- Base shots per second prior to multiplier adjustments.
]=]
local function computeShotsPerSecond(level)
    local base = TurretSettings.BaseShotsPerSecond or 0
    local pct = TurretSettings.ShotsPerLevelPct or 0
    local effectiveLevel = math.max(level - 1, 0)

    return base * (1 + pct * effectiveLevel)
end

local function cloneArray(array)
    if type(array) ~= "table" then
        return nil
    end

    local copy = {}
    for index, value in ipairs(array) do
        copy[index] = value
    end

    return copy
end

local function cloneDictionary(dictionary)
    if type(dictionary) ~= "table" then
        return nil
    end

    local copy = {}
    for key, value in pairs(dictionary) do
        copy[key] = value
    end

    return copy
end

local function normalizeWeights(weights)
    if typeof(weights) ~= "table" then
        return nil
    end

    local normalized = {}
    for key, value in pairs(weights) do
        local numeric = tonumber(value)
        if numeric and numeric > 0 then
            normalized[key] = numeric
        end
    end

    if next(normalized) == nil then
        return nil
    end

    return normalized
end

--[=[
    Builds the fruit roster lookup used by the bag generator.
    @param rosterOverride table? -- Optional roster definition supplied by callers.
    @return table -- Table keyed by fruit id with config entries.
]=]
local function resolveRoster(rosterOverride)
    if typeof(rosterOverride) ~= "table" then
        local roster = FruitConfig.All and FruitConfig.All() or FruitConfig.Roster
        if type(roster) == "function" then
            roster = roster()
        end
        return roster
    end

    if #rosterOverride > 0 then
        local roster = {}
        for _, fruitId in ipairs(rosterOverride) do
            local entry
            if typeof(fruitId) == "string" or typeof(fruitId) == "number" then
                if typeof(FruitConfig.Get) == "function" then
                    entry = FruitConfig.Get(fruitId)
                end
                if entry == nil then
                    local all = FruitConfig.All and FruitConfig.All()
                    if type(all) == "function" then
                        all = all()
                    end
                    if type(all) == "table" then
                        entry = all[fruitId]
                    end
                end
            elseif typeof(fruitId) == "table" then
                entry = fruitId
                fruitId = entry.Id
            end

            if type(entry) == "table" then
                local id = entry.Id or fruitId
                if id ~= nil then
                    roster[id] = entry
                end
            end
        end

        if next(roster) ~= nil then
            return roster
        end
    else
        local roster = {}
        for key, value in pairs(rosterOverride) do
            if type(value) == "table" then
                local id = value.Id or key
                if id ~= nil then
                    roster[id] = value
                end
            end
        end

        if next(roster) ~= nil then
            return roster
        end
    end

    local fallback = FruitConfig.All and FruitConfig.All() or FruitConfig.Roster
    if type(fallback) == "function" then
        fallback = fallback()
    end

    return fallback
end

--[=[
    Produces a generator function that yields fruit identifiers on demand.
    @param rng Random -- Random number generator dedicated to the arena state.
    @param rosterOverride table? -- Optional roster configuration.
    @param weightsOverride table? -- Optional weighting overrides per fruit id.
    @return () -> any -- Iterator returning the next fruit identifier.
]=]
local function buildFruitBag(rng, rosterOverride, weightsOverride)
    local roster = resolveRoster(rosterOverride)
    local weights = normalizeWeights(weightsOverride)
    local bag = {}

    if type(roster) == "function" then
        roster = roster()
    end

    for fruitId, entry in pairs(roster) do
        local id = entry and entry.Id or fruitId
        if id ~= nil then
            local weight = 1
            if weights then
                local overrideWeight = weights[id] or weights[fruitId]
                if typeof(overrideWeight) == "number" then
                    weight = overrideWeight
                end
            end

            weight = math.max(0, weight)
            if weight > 0 then
                local copies = math.max(1, math.floor(weight + 0.5))
                for _ = 1, copies do
                    table.insert(bag, id)
                end
            end
        end
    end

    if #bag == 0 then
        if rosterOverride ~= nil or weightsOverride ~= nil then
            return buildFruitBag(rng)
        end

        return function()
            return nil
        end
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

--[=[
    Sanitizes multiplier inputs so callers can safely pass numbers or strings.
    @param value any -- Proposed multiplier value.
    @return number -- Clamped multiplier between MIN_RATE_MULTIPLIER and MAX_RATE_MULTIPLIER.
]=]
local function normalizeMultiplier(value)
    local numeric = tonumber(value)
    if not numeric then
        return DEFAULT_RATE_MULTIPLIER
    end
    if numeric < MIN_RATE_MULTIPLIER then
        return MIN_RATE_MULTIPLIER
    end
    if numeric > MAX_RATE_MULTIPLIER then
        numeric = MAX_RATE_MULTIPLIER
    end
    return numeric
end

local function getRateMultiplier(state)
    if not state then
        return DEFAULT_RATE_MULTIPLIER
    end
    local multiplier = state.rateMultiplier
    if typeof(multiplier) ~= "number" then
        return DEFAULT_RATE_MULTIPLIER
    end
    if multiplier < MIN_RATE_MULTIPLIER then
        multiplier = MIN_RATE_MULTIPLIER
        state.rateMultiplier = multiplier
    elseif multiplier > MAX_RATE_MULTIPLIER then
        multiplier = MAX_RATE_MULTIPLIER
        state.rateMultiplier = multiplier
    end
    return multiplier
end

--[=[
    Applies context hints from callers to influence the active arena state.
    @param state table -- Arena state table being mutated.
    @param context any -- Context object (number or table) describing overrides.
]=]
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

    local rosterChanged = false
    if typeof(context.fruitRoster) == "table" then
        if context.fruitRoster ~= state.lastRosterContext then
            state.lastRosterContext = context.fruitRoster
            if #context.fruitRoster > 0 then
                state.fruitRosterOverride = cloneArray(context.fruitRoster) or {}
            else
                state.fruitRosterOverride = cloneDictionary(context.fruitRoster) or {}
            end
            rosterChanged = true
        end
    elseif context.fruitRoster == nil and state.lastRosterContext ~= nil then
        state.lastRosterContext = nil
        state.fruitRosterOverride = nil
        rosterChanged = true
    end

    local weightsChanged = false
    if typeof(context.fruitWeights) == "table" then
        if context.fruitWeights ~= state.lastWeightsContext then
            state.lastWeightsContext = context.fruitWeights
            state.fruitWeightsOverride = cloneDictionary(context.fruitWeights)
            weightsChanged = true
        end
    elseif context.fruitWeights == nil and state.lastWeightsContext ~= nil then
        state.lastWeightsContext = nil
        state.fruitWeightsOverride = nil
        weightsChanged = true
    end

    if rosterChanged or weightsChanged then
        state.nextFruit = buildFruitBag(state.rng, state.fruitRosterOverride, state.fruitWeightsOverride)
    end

    local rateMultiplier
    if typeof(context.fireRateMultiplier) == "number" then
        rateMultiplier = math.max(0, context.fireRateMultiplier)
    elseif typeof(context.fireRatePenalty) == "number" then
        rateMultiplier = math.max(0, 1 - context.fireRatePenalty)
    end

    if rateMultiplier ~= nil then
        state.rateMultiplier = rateMultiplier
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

        local rateMultiplier = getRateMultiplier(state)
        local shotsPerSecond = computeShotsPerSecond(level) * rateMultiplier
        local shotsPerSecond = computeShotsPerSecond(level)
        local multiplier = state.rateMultiplier
        if typeof(multiplier) == "number" and multiplier >= 0 then
            shotsPerSecond *= multiplier
        end
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

--[=[
    Ensures an arena loop is running and applies any provided context.
    @param arenaId any -- Identifier of the arena to start or refresh.
    @param context any -- Optional context passed through scheduling helpers.
    @return boolean -- True if the arena loop is active after the call.
]=]
local function startArena(arenaId, context)
    assert(arenaId ~= nil, "arenaId is required")
    local arenaKey = resolveArenaKey(arenaId)
    assert(arenaKey ~= nil and arenaKey ~= "", "arenaId is required")

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

    local state = arenaStates[arenaKey]
    if state then
        applyContext(state, context)
        if pendingRateMultipliers[arenaKey] ~= nil then
            state.rateMultiplier = normalizeMultiplier(pendingRateMultipliers[arenaKey])
            pendingRateMultipliers[arenaKey] = nil
        end
        getRateMultiplier(state)
        if not state.running then
            state.running = true
            state.lastShotTime = os.clock()
            state.thread = task.spawn(runArena, state)
        end
        return true
    end

    state = {
        arenaId = arenaKey,
        running = true,
        rng = Random.new(),
        rateMultiplier = 1,
        fruitRosterOverride = nil,
        fruitWeightsOverride = nil,
        lastRosterContext = nil,
        lastWeightsContext = nil,
    }

    state.rateMultiplier = normalizeMultiplier(pendingRateMultipliers[arenaKey])
    pendingRateMultipliers[arenaKey] = nil

    state.nextFruit = buildFruitBag(state.rng)
    applyContext(state, context)

    arenaStates[arenaKey] = state
    state.thread = task.spawn(runArena, state)

    return true
end

--[=[
    Internal helper that records per-arena firing multipliers, even before start.
    @param arenaId any -- Target arena identifier.
    @param multiplier any -- Value to normalize and store.
    @return boolean, number? -- Success flag and resulting multiplier.
]=]
local function setRateMultiplierInternal(arenaId, multiplier)
    local key = resolveArenaKey(arenaId)
    if not key then
        return false, "InvalidArena"
    end
    local numeric = normalizeMultiplier(multiplier)
    local state = arenaStates[key]
    if state then
        state.rateMultiplier = numeric
    else
        pendingRateMultipliers[key] = numeric
    end
    return true, numeric
end

--[=[
    Reads the currently effective multiplier for an arena.
    @param arenaId any -- Target arena identifier.
    @return number -- Active multiplier or the default when unset.
]=]
local function getRateMultiplierForArena(arenaId)
    local key = resolveArenaKey(arenaId)
    if not key then
        return DEFAULT_RATE_MULTIPLIER
    end
    local state = arenaStates[key]
    if state then
        return getRateMultiplier(state)
    end
    local pending = pendingRateMultipliers[key]
    if pending ~= nil then
        return normalizeMultiplier(pending)
    end
    return DEFAULT_RATE_MULTIPLIER
end

local function stopArena(arenaId)
    local arenaKey = resolveArenaKey(arenaId)
    if not arenaKey then
        return
    end

    local state = arenaStates[arenaKey]
    if not state then
        return
    end

    state.running = false
    arenaStates[arenaKey] = nil
end

TurretControllerServer.Start = startArena
TurretControllerServer.Stop = stopArena

--[=[
    Starts or refreshes the turret loop for an arena using method-call syntax.
    @param arenaId any -- Arena identifier to run.
    @param context any -- Optional context forwarded to the scheduler.
    @return boolean -- True if scheduling is active after the call.
]=]
function TurretControllerServer:Start(arenaId, context)
    return startArena(arenaId, context)
end

--[=[
    Stops the scheduled turret loop for the supplied arena.
    @param arenaId any -- Arena identifier to shut down.
]=]
function TurretControllerServer:Stop(arenaId)
    return stopArena(arenaId)
end

--[=[
    Convenience entry point for legacy APIs that only provide a level hint.
    @param arenaId any -- Arena identifier to schedule.
    @param level any -- Level context forwarded to `startArena`.
]=]
function TurretControllerServer.SchedulePattern(arenaId, level)
    return startArena(arenaId, level)
end

function TurretControllerServer:SchedulePattern(arenaId, level)
    return startArena(arenaId, level)
end

--[=[
    Schedules arenas using richer context data, typically lane counts or weights.
    @param _ any -- Legacy first argument ignored in old call sites.
    @param arenaId any -- Arena identifier to schedule.
    @param context any -- Context forwarded to `startArena`.
]=]
function TurretControllerServer.SchedulePatterns(_, arenaId, context)
    return startArena(arenaId, context)
end

function TurretControllerServer:SchedulePatterns(arenaId, context)
    return startArena(arenaId, context)
end

--[=[
    Public wrapper for setting arena fire-rate multipliers regardless of call style.
    @param arenaIdOrSelf any -- Arena identifier or self reference when called with ':' syntax.
    @param multiplierOrArenaId any -- Either the multiplier or arena id depending on invocation style.
    @param maybeMultiplier any -- Optional multiplier when called with ':' syntax.
    @return boolean, number? -- Success flag and resulting multiplier.
]=]
function TurretControllerServer:SetRateMultiplier(arenaIdOrSelf, multiplierOrArenaId, maybeMultiplier)
    local arenaId
    local multiplier
    if maybeMultiplier ~= nil then
        arenaId = multiplierOrArenaId
        multiplier = maybeMultiplier
    else
        arenaId = arenaIdOrSelf
        multiplier = multiplierOrArenaId
    end
    return setRateMultiplierInternal(arenaId, multiplier)
end

--[=[
    Retrieves the active multiplier for an arena.
    @param arenaIdOrSelf any -- Arena identifier or self reference.
    @param maybeArenaId any -- Optional arena id when using ':' syntax.
    @return number -- Effective multiplier currently applied.
]=]
function TurretControllerServer:GetRateMultiplier(arenaIdOrSelf, maybeArenaId)
    local arenaId
    if maybeArenaId ~= nil then
        arenaId = maybeArenaId
    else
        arenaId = arenaIdOrSelf
    end
    return getRateMultiplierForArena(arenaId)
end

return TurretControllerServer
