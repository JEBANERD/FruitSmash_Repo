local ReplicatedStorage = game:GetService("ReplicatedStorage")

local HUDServer = require(script.Parent:WaitForChild("HUDServer"))
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("RemoteBootstrap"))
local GameConfigModule = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("GameConfig"))
local GameConfig = typeof(GameConfigModule.Get) == "function" and GameConfigModule.Get() or GameConfigModule

local ArenaServer = require(script.Parent:WaitForChild("ArenaServer"))

local EconomyServer
do
    local economyFolder = ServerScriptService:FindFirstChild("Economy")
    local economyModule = economyFolder and economyFolder:FindFirstChild("EconomyServer")
    if economyModule then
        local ok, result = pcall(require, economyModule)
        if ok then
            EconomyServer = result
        else
            warn(string.format("[RoundDirectorServer] Failed to require EconomyServer: %s", tostring(result)))
        end
    end
end

local TurretController
local turretModule = script.Parent:FindFirstChild("TurretControllerServer")
if turretModule then
    local ok, result = pcall(require, turretModule)
    if ok then
        TurretController = result
    else
        warn(string.format("[RoundDirectorServer] Failed to require TurretControllerServer: %s", result))
    end
end

local roundSettings = GameConfig.Rounds or {}
local DEFAULT_PREP_SECONDS = roundSettings.PrepSeconds or 30
local SKIP_PREP_SECONDS = roundSettings.PrepFloorButtonSeconds or 3
local INTER_WAVE_SECONDS = roundSettings.InterWaveSeconds or 0
local WAVE_DURATION_SECONDS = roundSettings.WaveDurationSeconds or 45
local WAVES_PER_LEVEL = roundSettings.WavesPerLevel or 5
local SHOP_SECONDS = roundSettings.ShopSeconds or 30

local RoundDirectorServer = {}
local activeStates = {}

local function updateArenaStateSnapshot(state)
    if not ArenaServer or typeof(ArenaServer.GetArenaState) ~= "function" then
        return
    end

    if not state.arenaState then
        state.arenaState = ArenaServer.GetArenaState(state.arenaId)
    end

    if state.arenaState then
        state.arenaState.level = state.level
        state.arenaState.wave = state.wave
        state.arenaState.phase = state.phase
    end
end

local function logPhase(state)
    print(string.format("[RoundDirectorServer] arena=%s phase=%s level=%d wave=%d", state.arenaId, state.phase, state.level, state.wave))
end

local function broadcastWaveChange(state)
    if not HUDServer or typeof(HUDServer.WaveChanged) ~= "function" then
        return
    end

    local waveValue = state.phase == "Wave" and state.wave or 0
    HUDServer.WaveChanged(state.arenaId, waveValue, state.level, state.phase)
end

local function gatherArenaPlayers(state)
    local recipients = {}
    local seen = {}

    local arenaState = state and state.arenaState
    if type(arenaState) == "table" then
        local statePlayers = arenaState.players
        if type(statePlayers) == "table" then
            for _, entry in pairs(statePlayers) do
                local player = entry
                if typeof(entry) == "table" then
                    player = entry.player or entry.Player or entry.owner
                end

                if typeof(player) == "Instance" and player:IsA("Player") and not seen[player] then
                    table.insert(recipients, player)
                    seen[player] = true
                end
            end
        end
    end

    local arenaId = state and state.arenaId
    local partyId
    if type(arenaState) == "table" then
        partyId = arenaState.partyId or arenaState.PartyId or arenaState.partyID
    end

    for _, player in ipairs(Players:GetPlayers()) do
        if not seen[player] then
            local matches = false
            if arenaId then
                local playerArena = player:GetAttribute("ArenaId")
                if playerArena and tostring(playerArena) == tostring(arenaId) then
                    matches = true
                end
            end

            if not matches and partyId then
                local playerParty = player:GetAttribute("PartyId")
                if playerParty and tostring(playerParty) == tostring(partyId) then
                    matches = true
                end
            end

            if matches then
                table.insert(recipients, player)
                seen[player] = true
            end
        end
    end

    if #recipients == 0 then
        for _, player in ipairs(Players:GetPlayers()) do
            table.insert(recipients, player)
        end
    end

    return recipients
end

local function grantWaveBonus(state)
    if not EconomyServer or typeof(EconomyServer.GrantWaveClear) ~= "function" then
        return
    end

    local players = gatherArenaPlayers(state)
    if #players == 0 then
        return
    end

    local levelValue = state and state.level or 0
    local ok, err = pcall(EconomyServer.GrantWaveClear, players, levelValue)
    if not ok then
        warn(string.format("[RoundDirectorServer] GrantWaveClear failed: %s", tostring(err)))
    end
end

local function grantLevelBonus(state, level)
    if not EconomyServer or typeof(EconomyServer.GrantLevelClear) ~= "function" then
        return
    end

    local players = gatherArenaPlayers(state)
    if #players == 0 then
        return
    end

    local levelValue = level or (state and state.level) or 0
    local ok, err = pcall(EconomyServer.GrantLevelClear, players, levelValue)
    if not ok then
        warn(string.format("[RoundDirectorServer] GrantLevelClear failed: %s", tostring(err)))
    end
end

local function sendPrepTimer(state, seconds)
    if not HUDServer or typeof(HUDServer.BroadcastPrep) ~= "function" then
        return
    end

    HUDServer.BroadcastPrep(state.arenaId, seconds)
end

local function scheduleWave(state)
    if not TurretController then
        return
    end

    local context = {
        arenaId = state.arenaId,
        level = state.level,
        wave = state.wave,
    }

    if typeof(TurretController.ScheduleWave) == "function" then
        local ok, err = pcall(TurretController.ScheduleWave, TurretController, state.arenaId, context)
        if not ok then
            local okDirect, errDirect = pcall(TurretController.ScheduleWave, state.arenaId, context)
            if not okDirect then
                warn(string.format("[RoundDirectorServer] ScheduleWave failed: %s", errDirect))
            end
        end
        return
    end

    if typeof(TurretController.ScheduleWavePatterns) == "function" then
        local ok, err = pcall(TurretController.ScheduleWavePatterns, TurretController, state.arenaId, context)
        if not ok then
            local okDirect, errDirect = pcall(TurretController.ScheduleWavePatterns, state.arenaId, context)
            if not okDirect then
                warn(string.format("[RoundDirectorServer] ScheduleWavePatterns failed: %s", errDirect))
            end
        end
        return
    end

    if typeof(TurretController.SchedulePattern) == "function" then
        local ok, err = pcall(TurretController.SchedulePattern, TurretController, state.arenaId, state.level, state.wave)
        if not ok then
            local okDirect, errDirect = pcall(TurretController.SchedulePattern, state.arenaId, state.level, state.wave)
            if not okDirect then
                warn(string.format("[RoundDirectorServer] SchedulePattern failed: %s", errDirect))
            end
        end
    end
end

local function runPrep(state)
    state.phase = "Prep"
    state.wave = 0
    state.prepEndTime = os.clock() + DEFAULT_PREP_SECONDS

    updateArenaStateSnapshot(state)
    logPhase(state)

    sendPrepTimer(state, DEFAULT_PREP_SECONDS)

    while state.running do
        local remaining = state.prepEndTime - os.clock()
        if remaining <= 0 then
            break
        end

        task.wait(0.1)
    end

    if not state.running then
        return false
    end

    sendPrepTimer(state, 0)
    state.prepEndTime = nil

    return true
end

local function runInterWave(state)
    if INTER_WAVE_SECONDS <= 0 then
        return state.running
    end

    local endTime = os.clock() + INTER_WAVE_SECONDS

    while state.running and os.clock() < endTime do
        task.wait(0.1)
    end

    return state.running
end

local function runWave(state, waveNumber)
    state.phase = "Wave"
    state.wave = waveNumber

    updateArenaStateSnapshot(state)
    logPhase(state)
    broadcastWaveChange(state)
    scheduleWave(state)

    local waveEnd = os.clock() + WAVE_DURATION_SECONDS

    while state.running and os.clock() < waveEnd do
        task.wait(0.1)
    end

    if state.running then
        grantWaveBonus(state)
    end

    return state.running
end

local function runShop(state)
    state.phase = "Shop"
    state.wave = 0

    updateArenaStateSnapshot(state)
    logPhase(state)
    broadcastWaveChange(state)

    local shopEnd = os.clock() + SHOP_SECONDS

    while state.running and os.clock() < shopEnd do
        task.wait(0.1)
    end

    if not state.running then
        return false
    end

    grantLevelBonus(state, state.level)

    state.level += 1
    updateArenaStateSnapshot(state)
    broadcastWaveChange(state)

    return true
end

local function runLevel(state)
    if not runPrep(state) then
        return false
    end

    for waveNumber = 1, WAVES_PER_LEVEL do
        if not runWave(state, waveNumber) then
            return false
        end

        if waveNumber < WAVES_PER_LEVEL and not runInterWave(state) then
            return false
        end
    end

    if not runShop(state) then
        return false
    end

    return state.running
end

local function runLoop(state)
    while state.running do
        if not runLevel(state) then
            break
        end
    end

    if activeStates[state.arenaId] == state then
        activeStates[state.arenaId] = nil
    end
end

function RoundDirectorServer.Start(arenaId, options)
    assert(arenaId ~= nil, "arenaId is required")

    if activeStates[arenaId] then
        RoundDirectorServer.Abort(arenaId)
    end

    local arenaState = ArenaServer.GetArenaState and ArenaServer.GetArenaState(arenaId) or nil

    local startLevel = 1
    if arenaState and typeof(arenaState.level) == "number" then
        startLevel = arenaState.level
    end

    if options and typeof(options.StartLevel) == "number" then
        startLevel = math.max(1, math.floor(options.StartLevel))
    end

    if arenaState then
        arenaState.level = startLevel
        arenaState.wave = 0
        arenaState.phase = "Prep"
    end

    local state = {
        arenaId = arenaId,
        level = startLevel,
        wave = 0,
        phase = "Prep",
        running = true,
        prepEndTime = nil,
        arenaState = arenaState,
    }

    activeStates[arenaId] = state

    task.spawn(runLoop, state)

    return state
end

function RoundDirectorServer.Abort(arenaId)
    local state = activeStates[arenaId]
    if not state then
        return
    end

    state.running = false
    activeStates[arenaId] = nil
    sendPrepTimer(state, 0)
end

function RoundDirectorServer.SkipPrep(arenaId)
    local state = activeStates[arenaId]
    if not state or not state.running or state.phase ~= "Prep" or not state.prepEndTime then
        return false
    end

    local newEndTime = os.clock() + SKIP_PREP_SECONDS
    if newEndTime >= state.prepEndTime then
        return false
    end

    state.prepEndTime = newEndTime

    local remaining = math.max(0, math.ceil(state.prepEndTime - os.clock()))
    sendPrepTimer(state, remaining)
    print(string.format("[RoundDirectorServer] arena=%s prep skipped; remaining=%d", state.arenaId, remaining))

    return true
end

function RoundDirectorServer.GetState(arenaId)
    local state = activeStates[arenaId]
    if not state then
        return nil
    end

    return {
        phase = state.phase,
        level = state.level,
        wave = state.wave,
    }
end

function RoundDirectorServer._debugGetInternalState(arenaId)
    return activeStates[arenaId]
end

return RoundDirectorServer
