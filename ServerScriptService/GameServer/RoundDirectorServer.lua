local ReplicatedStorage = game:GetService("ReplicatedStorage")

local function safeRequire(instance)
    if not instance then
        return nil
    end

    local ok, result = pcall(require, instance)
    if not ok then
        warn(string.format("[RoundDirectorServer] Failed to require %s: %s", instance:GetFullName(), result))
        return nil
    end

    return result
end

local GameConfigModule = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("GameConfig"))
local GameConfig = GameConfigModule.Get()
local RoundConfig = GameConfig.Rounds or {}
local LaneConfig = GameConfig.Lanes or {}

local DEFAULT_PREP_SECONDS = RoundConfig.PrepSeconds or 30
local DEFAULT_BUTTON_PREP_SECONDS = RoundConfig.PrepFloorButtonSeconds or DEFAULT_PREP_SECONDS
local DEFAULT_INTER_WAVE_SECONDS = RoundConfig.InterWaveSeconds or 0
local DEFAULT_WAVE_DURATION_SECONDS = RoundConfig.WaveDurationSeconds or 45
local DEFAULT_WAVES_PER_LEVEL = RoundConfig.WavesPerLevel or 5
local DEFAULT_SPIKE_INTERVAL = RoundConfig.SpikeLevelInterval or 10

local function shallowCopy(source)
    local target = {}
    if source then
        for key, value in pairs(source) do
            target[key] = value
        end
    end

    return target
end

local function buildLaneTargets()
    local mapping = {}
    local ordered = {}
    local unlockLevels = LaneConfig.UnlockAt or {}
    local startCount = LaneConfig.StartCount or 0
    local maxCount = LaneConfig.MaxCount or startCount
    local totalExtra = math.max(maxCount - startCount, 0)
    local unlockCount = #unlockLevels

    if unlockCount == 0 or totalExtra == 0 then
        return mapping, ordered
    end

    local baseGain = math.floor(totalExtra / unlockCount)
    local remainder = totalExtra % unlockCount
    local current = startCount

    for index, level in ipairs(unlockLevels) do
        local increment = baseGain
        if remainder > 0 and index <= remainder then
            increment += 1
        end

        current = math.min(current + increment, maxCount)
        mapping[level] = current
        table.insert(ordered, { level = level, count = current })
    end

    table.sort(ordered, function(a, b)
        return a.level < b.level
    end)

    return mapping, ordered
end

local _, laneTargetOrdered = buildLaneTargets()

local function laneCountForLevel(level)
    local startCount = LaneConfig.StartCount or 0
    local maxCount = LaneConfig.MaxCount or startCount
    local lanes = startCount

    for _, entry in ipairs(laneTargetOrdered) do
        if level >= entry.level and entry.count > lanes then
            lanes = entry.count
        end
    end

    return math.clamp(lanes, 0, maxCount)
end

local RoundDirectorServer = {}
local stateByArena = {}
local baseDependencies

local function buildBaseDependencies()
    if baseDependencies then
        return baseDependencies
    end

    local gameServerFolder = script.Parent
    local economyFolder = script.Parent.Parent:FindFirstChild("Economy")

    baseDependencies = {
        TurretController = safeRequire(gameServerFolder:FindFirstChild("TurretControllerServer")),
        ArenaServer = safeRequire(gameServerFolder:FindFirstChild("ArenaServer")),
        EconomyServer = economyFolder and safeRequire(economyFolder:FindFirstChild("EconomyServer")) or nil,
    }

    return baseDependencies
end

local function resolveDependencies(overrides)
    local resolved = shallowCopy(buildBaseDependencies())

    if overrides then
        for key, value in pairs(overrides) do
            resolved[key] = value
        end
    end

    return resolved
end

local function tryCall(target, methodName, ...)
    if not target then
        return nil
    end

    local method = target[methodName]
    if type(method) ~= "function" then
        return nil
    end

    local ok, result = pcall(method, target, ...)
    if not ok then
        local okDirect, directResult = pcall(method, ...)
        if not okDirect then
            warn(string.format("[RoundDirectorServer] %s call failed: %s", methodName, directResult))
        end

        return okDirect and directResult or nil
    end

    return result
end

local function connectSignal(signal, handler)
    if signal == nil then
        return nil
    end

    local signalType = typeof(signal)

    if signalType == "RBXScriptSignal" then
        return signal:Connect(handler)
    elseif signalType == "Instance" then
        if signal:IsA("BindableEvent") then
            return signal.Event:Connect(handler)
        elseif signal:IsA("BindableFunction") then
            local connection = {}

            function connection:Disconnect() end

            local original = signal.OnInvoke
            signal.OnInvoke = function(...)
                if handler then
                    handler(...)
                end
                if original then
                    return original(...)
                end
            end

            return connection
        end
    elseif signalType == "table" then
        if type(signal.Connect) == "function" then
            return signal:Connect(handler)
        elseif signal.Event and typeof(signal.Event) == "RBXScriptSignal" then
            return signal.Event:Connect(handler)
        end
    elseif signalType == "function" then
        local disconnected = false
        task.spawn(function()
            if not disconnected then
                signal(handler)
            end
        end)

        return {
            Disconnect = function()
                disconnected = true
            end,
        }
    end

    return nil
end

local function isSpikeLevel(level)
    if DEFAULT_SPIKE_INTERVAL <= 0 then
        return false
    end

    return level % DEFAULT_SPIKE_INTERVAL == 0
end

local function runPrep(state)
    local prepSeconds = DEFAULT_PREP_SECONDS
    local buttonSeconds = DEFAULT_BUTTON_PREP_SECONDS
    local prepEnd = os.clock() + prepSeconds

    local function shortCircuit()
        local adjusted = os.clock() + buttonSeconds
        if adjusted < prepEnd then
            prepEnd = adjusted
        end
    end

    local buttonSignal = state.options and state.options.FloorButtonSignal or nil

    if not buttonSignal then
        local arenaServer = state.dependencies.ArenaServer
        if arenaServer and type(arenaServer.GetFloorButtonSignal) == "function" then
            local ok, fetchedSignal = pcall(arenaServer.GetFloorButtonSignal, arenaServer, state.arenaId)
            if ok then
                buttonSignal = fetchedSignal
            else
                warn(string.format("[RoundDirectorServer] Failed to fetch floor button signal: %s", fetchedSignal))
            end
        end
    end

    local connection = connectSignal(buttonSignal, shortCircuit)

    while state.running and os.clock() < prepEnd do
        task.wait(0.25)
    end

    if connection and type(connection.Disconnect) == "function" then
        connection:Disconnect()
    end

    return state.running
end

local function awardWave(state, waveNumber)
    local economy = state.dependencies.EconomyServer
    if not economy then
        return
    end

    if type(economy.QueueWaveReward) == "function" then
        local ok, err = pcall(economy.QueueWaveReward, economy, state.arenaId, state.level, waveNumber)
        if not ok then
            local okDirect, directErr = pcall(economy.QueueWaveReward, state.arenaId, state.level, waveNumber)
            if not okDirect then
                warn(string.format("[RoundDirectorServer] QueueWaveReward failed: %s", directErr))
            end
        end
        return
    end

    if type(economy.AwardWaveReward) == "function" then
        local ok, err = pcall(economy.AwardWaveReward, economy, state.arenaId, state.level, waveNumber)
        if not ok then
            warn(string.format("[RoundDirectorServer] AwardWaveReward failed: %s", err))
        end
    end
end

local function awardLevel(state)
    local economy = state.dependencies.EconomyServer
    if not economy then
        return
    end

    if type(economy.QueueLevelReward) == "function" then
        local ok, err = pcall(economy.QueueLevelReward, economy, state.arenaId, state.level)
        if not ok then
            local okDirect, directErr = pcall(economy.QueueLevelReward, state.arenaId, state.level)
            if not okDirect then
                warn(string.format("[RoundDirectorServer] QueueLevelReward failed: %s", directErr))
            end
        end
        return
    end

    if type(economy.AwardLevelReward) == "function" then
        local ok, err = pcall(economy.AwardLevelReward, economy, state.arenaId, state.level)
        if not ok then
            warn(string.format("[RoundDirectorServer] AwardLevelReward failed: %s", err))
        end
    end
end

local function unlockLanesIfNeeded(state)
    local target = laneCountForLevel(state.level)

    if target <= state.activeLanes then
        return
    end

    state.activeLanes = target

    tryCall(state.dependencies.ArenaServer, "UnlockLanes", state.arenaId, target)
    tryCall(state.dependencies.ArenaServer, "SetLaneCount", state.arenaId, target)
end

local function scheduleWave(state, waveNumber)
    local turret = state.dependencies.TurretController
    if not turret then
        return
    end

    local context = {
        arenaId = state.arenaId,
        level = state.level,
        wave = waveNumber,
        lanes = state.activeLanes,
        spikes = isSpikeLevel(state.level),
    }

    if type(turret.ScheduleWave) == "function" then
        local ok, err = pcall(turret.ScheduleWave, turret, state.arenaId, context)
        if not ok then
            warn(string.format("[RoundDirectorServer] ScheduleWave failed: %s", err))
        end
        return
    end

    if type(turret.ScheduleWavePatterns) == "function" then
        local ok, err = pcall(turret.ScheduleWavePatterns, turret, state.arenaId, context)
        if not ok then
            warn(string.format("[RoundDirectorServer] ScheduleWavePatterns failed: %s", err))
        end
        return
    end

    if type(turret.SchedulePatterns) == "function" then
        local ok, err = pcall(turret.SchedulePatterns, turret, state.arenaId, context)
        if not ok then
            warn(string.format("[RoundDirectorServer] SchedulePatterns failed: %s", err))
        end
    end
end

local function runWave(state, waveNumber)
    state.currentWave = waveNumber
    scheduleWave(state, waveNumber)

    local waveEnd = os.clock() + DEFAULT_WAVE_DURATION_SECONDS
    while state.running and os.clock() < waveEnd do
        task.wait(0.25)
    end

    if not state.running then
        return false
    end

    awardWave(state, waveNumber)

    if waveNumber < DEFAULT_WAVES_PER_LEVEL and DEFAULT_INTER_WAVE_SECONDS > 0 then
        local breakEnd = os.clock() + DEFAULT_INTER_WAVE_SECONDS
        while state.running and os.clock() < breakEnd do
            task.wait(0.25)
        end
    end

    return state.running
end

local function updateSpikes(state)
    local enabled = isSpikeLevel(state.level)
    tryCall(state.dependencies.ArenaServer, "SetSpikeEnabled", state.arenaId, enabled)
    tryCall(state.dependencies.ArenaServer, "EnableSpikes", state.arenaId, enabled)
end

local function runLevel(state)
    updateSpikes(state)

    if not runPrep(state) then
        return false
    end

    for waveNumber = 1, DEFAULT_WAVES_PER_LEVEL do
        if not runWave(state, waveNumber) then
            return false
        end
    end

    awardLevel(state)

    state.level += 1
    unlockLanesIfNeeded(state)

    return state.running
end

local function runLoop(state)
    while state.running do
        if not runLevel(state) then
            break
        end
    end

    if stateByArena[state.arenaId] == state then
        stateByArena[state.arenaId] = nil
    end
end

function RoundDirectorServer.Start(arenaId, options)
    assert(arenaId ~= nil, "arenaId is required")

    if stateByArena[arenaId] then
        RoundDirectorServer.Stop(arenaId)
    end

    local resolvedOptions = options or {}
    local dependencies = resolveDependencies(resolvedOptions.Dependencies)

    local initialLevel = resolvedOptions.StartLevel or 1
    local initialLanes = resolvedOptions.InitialLaneCount or LaneConfig.StartCount or 0

    local state = {
        arenaId = arenaId,
        level = initialLevel,
        currentWave = 0,
        activeLanes = initialLanes,
        running = true,
        dependencies = dependencies,
        options = resolvedOptions,
    }

    stateByArena[arenaId] = state

    unlockLanesIfNeeded(state)
    tryCall(state.dependencies.ArenaServer, "SetLaneCount", state.arenaId, state.activeLanes)

    task.spawn(runLoop, state)

    return state
end

function RoundDirectorServer.Stop(arenaId)
    local state = stateByArena[arenaId]
    if not state then
        return
    end

    state.running = false
    if stateByArena[arenaId] == state then
        stateByArena[arenaId] = nil
    end
end

function RoundDirectorServer.GetState(arenaId)
    return stateByArena[arenaId]
end

return RoundDirectorServer
